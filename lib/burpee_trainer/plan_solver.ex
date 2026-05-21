defmodule BurpeeTrainer.PlanSolver do
  @moduledoc """
  Public entry point for session plan generation.

  Given a `%PlanSolver.Input{}` (burpee count, type, duration, pacing style,
  user level), finds the optimal pace and rest distribution via a joint MILP
  and returns a `%PlanSolver.Solution{}` wrapping the `%WorkoutPlan{}`.

  `sec_per_burpee` is solver-chosen, bounded below by `sustainable_ceiling/1`.
  Users never input a pace.
  """

  alias BurpeeTrainer.Milp.Highs
  alias BurpeeTrainer.PlanSolver.{Apply, Input, Lp, Solution}

  @sustainable_ceiling %{
    level_1a: 8.0,
    level_1b: 7.0,
    level_1c: 6.0,
    level_1d: 5.5,
    level_2: 5.0,
    level_3: 4.5,
    level_4: 4.0,
    graduated: 3.70
  }

  @default_reps_per_set %{six_count: 10, navy_seal: 5}

  @doc "Level-derived sustainable pace ceiling (sec/rep). Solver will not go faster."
  @spec sustainable_ceiling(atom) :: float
  def sustainable_ceiling(level), do: Map.get(@sustainable_ceiling, level, 8.0)

  @doc "Default reps-per-set for a given burpee type."
  @spec default_reps_per_set(atom) :: pos_integer
  def default_reps_per_set(type), do: Map.get(@default_reps_per_set, type, 10)

  @doc """
  Generate a `%Solution{}` from a `%PlanSolver.Input{}`.
  Returns `{:ok, solution}` or `{:error, [reason_string]}`.
  """
  @spec solve(Input.t()) :: {:ok, Solution.t()} | {:error, [String.t()]}
  def solve(%Input{} = input) do
    with {:ok, reps_per_set} <- resolve_reps_per_set(input),
         :ok <- preflight_check(input),
         {:ok, p, r, reservations} <- run_lp(input, reps_per_set),
         {:ok, plan} <- Apply.to_workout_plan(input, p, r, reservations) do
      {:ok, build_solution(p, plan, input, reps_per_set)}
    end
  end

  defp resolve_reps_per_set(%Input{pacing_style: :even}), do: {:ok, nil}

  defp resolve_reps_per_set(%Input{pacing_style: :unbroken} = input) do
    rps = input.reps_per_set || default_reps_per_set(input.burpee_type)

    if is_integer(rps) and rps > 0,
      do: {:ok, rps},
      else: {:error, ["reps_per_set must be a positive integer"]}
  end

  defp preflight_check(%Input{} = input) do
    ceiling = sustainable_ceiling(input.level)
    min_work = input.burpee_count_target * ceiling
    target_sec = input.target_duration_min * 60.0
    add_rest = Enum.reduce(input.additional_rests || [], 0.0, &(&1.rest_sec + &2))

    cond do
      min_work > target_sec ->
        {:error,
         [
           "#{input.burpee_count_target} reps at minimum pace #{ceiling}s/rep requires " <>
             "#{round(min_work)}s — target is #{round(target_sec)}s"
         ]}

      min_work + add_rest > target_sec ->
        {:error,
         [
           "work (#{round(min_work)}s) + additional rests (#{round(add_rest)}s) exceed " <>
             "target duration (#{round(target_sec)}s)"
         ]}

      true ->
        :ok
    end
  end

  defp run_lp(%Input{} = input, reps_per_set) do
    problem = Lp.build(input, reps_per_set)

    case Highs.solve(problem) do
      {:ok, %{r: r, p: p}} when is_float(p) ->
        reservations = recover_reservations(input, r)
        {:ok, p, r, reservations}

      {:ok, %{p: nil}} ->
        ceiling = sustainable_ceiling(input.level)
        {:ok, ceiling, [], []}

      {:error, :infeasible} ->
        {:error, [infeasibility_message(input)]}

      {:error, :timeout} ->
        {:error, ["plan solver timed out"]}

      {:error, {:exit, code, out}} ->
        {:error, ["plan solver failed (exit #{code}): #{out}"]}
    end
  end

  defp infeasibility_message(%Input{additional_rests: [_ | _] = rests}) do
    %{target_min: t} = Enum.max_by(rests, & &1.target_min)
    "Cannot place rest at minute #{t} within 30s of a rep boundary"
  end

  defp infeasibility_message(%Input{} = input) do
    target_sec = input.target_duration_min * 60.0
    "#{input.burpee_count_target} reps cannot fit in #{round(target_sec)}s at your level"
  end

  defp recover_reservations(%Input{additional_rests: []}, _r), do: []

  defp recover_reservations(%Input{additional_rests: rests}, r) when r != [] do
    {result, _taken} =
      rests
      |> Enum.sort_by(& &1.target_min)
      |> Enum.map_reduce(MapSet.new(), fn rest, taken ->
        slot =
          r
          |> Enum.with_index(1)
          |> Enum.reject(fn {_v, i} -> MapSet.member?(taken, i) end)
          |> Enum.min_by(fn {v, _i} -> abs(v - rest.rest_sec) end)
          |> elem(1)

        reservation = %{slot: slot, rest_sec: rest.rest_sec, target_min: rest.target_min}
        {reservation, MapSet.put(taken, slot)}
      end)

    result
  end

  defp recover_reservations(%Input{additional_rests: rests}, []) do
    rests
    |> Enum.sort_by(& &1.target_min)
    |> Enum.with_index(1)
    |> Enum.map(fn {r, i} -> %{slot: i, rest_sec: r.rest_sec, target_min: r.target_min} end)
  end

  defp build_solution(p, plan, %Input{} = input, reps_per_set) do
    n = input.burpee_count_target
    set_size = reps_per_set || n
    set_count = ceil(n / set_size)
    target_sec = input.target_duration_min * 60.0
    add_rest = Enum.reduce(input.additional_rests || [], 0.0, &(&1.rest_sec + &2))
    rest_sec = if set_count > 1, do: (target_sec - n * p - add_rest) / (set_count - 1), else: 0.0

    %Solution{
      sec_per_burpee: p,
      set_size: set_size,
      set_count: set_count,
      rest_sec: max(rest_sec, 0.0),
      duration_sec: n * p + max(rest_sec, 0.0) * (set_count - 1) + add_rest,
      plan: plan
    }
  end
end
