defmodule BurpeeTrainer.PlanSolver.Validator do
  @moduledoc """
  Deterministic validation boundary for PlanSolver outputs.

  The optimizer is not trusted just because it found a candidate. This module
  checks the user-owned workout contract after solving.
  """

  alias BurpeeTrainer.PlanSolver.{Input, Solution}
  alias BurpeeTrainer.Planner

  @duration_tolerance_sec 1.0
  @pace_tolerance 1.0e-6

  @spec validate(Solution.t(), Input.t()) :: :ok | {:error, term()}
  def validate(%Solution{} = solution, %Input{} = input) do
    with :ok <- validate_reps(solution, input),
         :ok <- validate_unbroken(solution, input),
         :ok <- validate_rest_shape(solution),
         :ok <- validate_duration(solution, input),
         :ok <- validate_pace(solution, input) do
      :ok
    end
  end

  defp validate_reps(%Solution{} = solution, %Input{} = input) do
    if Enum.sum(solution.set_pattern) == input.burpee_count_target and
         solution.burpee_count == input.burpee_count_target do
      :ok
    else
      {:error,
       {:rep_mismatch,
        %{expected: input.burpee_count_target, actual: Enum.sum(solution.set_pattern)}}}
    end
  end

  defp validate_duration(%Solution{} = solution, %Input{} = input) do
    target_sec = input.target_duration_min * 60.0
    computed = computed_duration(solution)

    if abs(computed - target_sec) <= @duration_tolerance_sec do
      :ok
    else
      {:error, {:duration_mismatch, %{expected_sec: target_sec, actual_sec: computed}}}
    end
  end

  defp validate_pace(%Solution{} = solution, %Input{} = _input) do
    fastest = Map.fetch!(solution.metadata, :pace_fastest_sec_per_rep)
    slowest = Map.fetch!(solution.metadata, :pace_slowest_sec_per_rep)

    cond do
      solution.sec_per_burpee < fastest - @pace_tolerance ->
        {:error,
         {:pace_too_fast, %{fastest_sec_per_rep: fastest, actual: solution.sec_per_burpee}}}

      solution.sec_per_burpee > slowest + @pace_tolerance ->
        {:error,
         {:pace_too_slow, %{slowest_sec_per_rep: slowest, actual: solution.sec_per_burpee}}}

      true ->
        :ok
    end
  end

  defp validate_rest_shape(%Solution{} = solution) do
    expected = max(length(solution.set_pattern) - 1, 0)

    if length(solution.rest_pattern_sec) == expected do
      :ok
    else
      {:error, :hidden_final_rest}
    end
  end

  defp validate_unbroken(
         %Solution{pacing_style: :unbroken} = solution,
         %Input{reps_per_set: reps, reps_per_set_fixed?: true}
       )
       when is_integer(reps) and reps > 0 do
    full_sets = Enum.drop(solution.set_pattern, -1)
    final_set = List.last(solution.set_pattern)

    cond do
      Enum.any?(full_sets, &(&1 != reps)) ->
        {:error, {:unbroken_reps_per_set_changed, %{expected: reps}}}

      is_integer(final_set) and final_set > reps ->
        {:error, {:unbroken_remainder_too_large, %{expected_max: reps, actual: final_set}}}

      true ->
        :ok
    end
  end

  defp validate_unbroken(_solution, _input), do: :ok

  defp computed_duration(%Solution{pacing_style: :even, plan: plan}) do
    plan
    |> Planner.summary()
    |> Map.fetch!(:duration_sec_total)
  end

  defp computed_duration(%Solution{} = solution) do
    Enum.sum(solution.set_pattern) * solution.sec_per_burpee + Enum.sum(solution.rest_pattern_sec)
  end
end
