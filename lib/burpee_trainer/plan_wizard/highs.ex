defmodule BurpeeTrainer.PlanWizard.Highs do
  @moduledoc """
  Invokes the HiGHS CLI to solve an `%Lp.Problem{}`.

  Workflow:
    1. Serialize the problem to MPS.
    2. Write to a uniquely-named temp file.
    3. Run `highs <mps> --solution_file <sol>`.
    4. Parse the solution file for status, objective, and `r_*` values.
    5. Clean up temp files.

  Configurable binary path via `:burpee_trainer, :highs_path` (default
  `"highs"`).
  """

  alias BurpeeTrainer.PlanWizard.Lp.Problem
  alias BurpeeTrainer.PlanWizard.Mps

  @options_file "highs_options.txt"

  @spec solve(Problem.t()) ::
          {:ok, %{r: [float], objective: float}}
          | {:error, :infeasible | :timeout | {:exit, integer, String.t()}}
  def solve(%Problem{} = problem) do
    mps = Mps.serialize(problem)
    base = "burpee_#{:erlang.unique_integer([:positive])}"
    tmp = System.tmp_dir!()
    mps_path = Path.join(tmp, "#{base}.mps")
    sol_path = Path.join(tmp, "#{base}.sol")

    try do
      File.write!(mps_path, mps)
      # HiGHS writes a log file to its CWD by default; cd into the temp dir
      # so the log lives there and gets cleaned up with everything else.
      run_highs(mps_path, sol_path, tmp, problem)
    after
      File.rm(mps_path)
      File.rm(sol_path)
    end
  end

  defp run_highs(mps_path, sol_path, cwd, problem) do
    bin = Application.get_env(:burpee_trainer, :highs_path, "highs")
    options_path = Application.app_dir(:burpee_trainer, ["priv", @options_file])

    args = [
      mps_path,
      "--solution_file",
      sol_path,
      "--options_file",
      options_path
    ]

    case System.cmd(bin, args, stderr_to_stdout: true, cd: cwd) do
      {output, 0} ->
        parse_solution(sol_path, output, problem)

      {output, code} ->
        {:error, {:exit, code, output}}
    end
  end

  defp parse_solution(sol_path, output, problem) do
    case File.read(sol_path) do
      {:ok, contents} ->
        status = status_line(contents)

        cond do
          status =~ ~r/infeasible/i -> {:error, :infeasible}
          status =~ ~r/time limit/i -> {:error, :timeout}
          status =~ ~r/optimal/i -> extract_values(contents, problem)
          true -> {:error, {:exit, 0, "unexpected status: #{status} / #{output}"}}
        end

      {:error, _} ->
        if output =~ ~r/infeasible/i,
          do: {:error, :infeasible},
          else: {:error, {:exit, 0, output}}
    end
  end

  defp status_line(contents) do
    case Regex.run(~r/Model status\s*:\s*(.*)/i, contents) do
      [_, status] -> String.trim(status)
      _ -> ""
    end
  end

  defp extract_values(contents, problem) do
    # HiGHS 1.14 solution style 1 format:
    #   Columns
    #       Index Status  Lower  Upper  Primal  Dual  Name
    #           0     LB      0    inf       0     0  r_1
    #   Rows
    #       ...
    columns_section =
      contents
      |> String.split(~r/^Columns\s*$/m, parts: 2)
      |> Enum.at(1, "")
      |> String.split(~r/^Rows\s*$/m, parts: 2)
      |> List.first()

    # HiGHS solution file column line layouts (all have Index as first token):
    #
    #   LP with status:   idx status lower upper primal dual name          (7)
    #   LP blank status:  idx lower  upper primal dual   name              (6)
    #   MIP with status:  idx status lower upper primal dual type name     (8)
    #   MIP blank status: idx lower  upper primal type   name              (6)
    #
    # Strategy: if second token (index 1) parses as a number → blank status,
    # primal is at index 3. Otherwise status is present, primal is at index 4.
    # Name is always last; skip the header row ("Index" at index 0).
    values =
      columns_section
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        parts = String.split(line, ~r/\s+/, trim: true)

        with [idx | _] <- parts,
             {_, ""} <- Integer.parse(idx) do
          name = List.last(parts)

          primal_idx =
            case parts do
              [_, second | _] ->
                case Float.parse(second) do
                  # second token is numeric → no status field → primal at position 3
                  {_, ""} -> 3
                  # second token is a label like LB/BS → primal at position 4
                  _ -> 4
                end

              _ ->
                nil
            end

          if primal_idx do
            primal_str = Enum.at(parts, primal_idx)

            case primal_str && Float.parse(primal_str) do
              {v, _} -> [{name, v}]
              _ -> []
            end
          else
            []
          end
        else
          _ -> []
        end
      end)
      |> Map.new()

    slot_count =
      problem.variables
      |> Enum.filter(&String.starts_with?(&1.name, "r_"))
      |> length()

    r =
      for i <- 1..slot_count,
          do: Map.get(values, "r_#{i}", 0.0) |> max(0.0)

    objective =
      case Regex.run(~r/Objective value\s*:\s*([\-0-9.eE+]+)/i, contents) do
        [_, v] -> parse_float(v)
        _ -> 0.0
      end

    {:ok, %{r: r, objective: objective}}
  end

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
