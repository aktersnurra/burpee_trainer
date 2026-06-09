defmodule BurpeeTrainer.PlanSolver.Milp do
  @moduledoc """
  Tiny HiGHS-backed MILP helper for selecting among precomputed linear options.

  This deliberately keeps the model linear: all nonlinear workout products such
  as reps × pace are precomputed on each option before the MILP is built.
  """

  @type option :: %{
          required(:id) => term(),
          required(:cost) => number(),
          required(:reps) => integer(),
          required(:duration_ds) => integer()
        }

  @spec select_option([option()], keyword()) :: {:ok, option()} | {:error, term()}
  def select_option(options, opts) when is_list(options) do
    target_reps = Keyword.fetch!(opts, :target_reps)
    target_duration_ds = Keyword.fetch!(opts, :target_duration_ds)

    with {:ok, highs} <- find_highs(),
         {:ok, dir} <- make_tmp_dir(),
         {:ok, model_file, solution_file} <-
           write_model(dir, options, target_reps, target_duration_ds),
         {:ok, selected_index} <- solve(highs, model_file, solution_file) do
      {:ok, Enum.at(options, selected_index)}
    end
  end

  defp find_highs do
    case System.find_executable("highs") do
      nil -> {:error, :highs_not_found}
      path -> {:ok, path}
    end
  end

  defp make_tmp_dir do
    dir =
      Path.join(System.tmp_dir!(), "burpee_trainer_highs_#{System.unique_integer([:positive])}")

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_model(dir, options, target_reps, target_duration_ds) do
    model_file = Path.join(dir, "model.lp")
    solution_file = Path.join(dir, "solution.txt")

    content = lp_content(options, target_reps, target_duration_ds)

    case File.write(model_file, content) do
      :ok -> {:ok, model_file, solution_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lp_content(options, target_reps, target_duration_ds) do
    vars = variable_names(options)

    """
    Minimize
     obj: #{linear_expr(options, vars, :cost)}
    Subject To
     choose: #{Enum.join(vars, " + ")} = 1
     reps: #{linear_expr(options, vars, :reps)} = #{target_reps}
     duration: #{linear_expr(options, vars, :duration_ds)} = #{target_duration_ds}
    Binary
     #{Enum.join(vars, " ")}
    End
    """
  end

  defp variable_names(options), do: Enum.map(1..length(options), &"x#{&1}")

  defp linear_expr(options, vars, field) do
    options
    |> Enum.zip(vars)
    |> Enum.map(fn {option, var} -> "#{Map.fetch!(option, field)} #{var}" end)
    |> Enum.join(" + ")
  end

  defp solve(highs, model_file, solution_file) do
    {output, status} =
      System.cmd(highs, [
        "--model_file",
        model_file,
        "--solution_file",
        solution_file,
        "--time_limit",
        "5"
      ])

    if status == 0 and String.contains?(output, "Status            Optimal") do
      parse_solution(solution_file)
    else
      {:error, :infeasible}
    end
  end

  defp parse_solution(solution_file) do
    with {:ok, content} <- File.read(solution_file),
         {var, _value} <- selected_variable(content) do
      "x" <> index = var
      {:ok, String.to_integer(index) - 1}
    else
      nil -> {:error, :infeasible}
      {:error, reason} -> {:error, reason}
    end
  end

  defp selected_variable(content) do
    content
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line) do
        ["x" <> _ = var, value] when value in ["1", "1.0"] -> {var, value}
        _ -> nil
      end
    end)
  end
end
