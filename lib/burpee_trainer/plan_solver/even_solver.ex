defmodule BurpeeTrainer.PlanSolver.EvenSolver do
  @moduledoc "Plan Solver v3 even pacing branch."

  alias BurpeeTrainer.PlanSolver.{BlockSpec, Infeasible, PacePolicy, Prescription}

  @spec solve(BurpeeTrainer.PlanSolver.Input.t(), PacePolicy.t()) ::
          {:ok, Prescription.t()} | {:error, Infeasible.t()}
  def solve(input, %PacePolicy{} = policy) do
    explicit_rest_total = Enum.reduce(input.explicit_rests || [], 0, &(&1.duration_sec + &2))

    available_average =
      (input.target_duration_sec - explicit_rest_total) / input.burpee_count_target

    cond do
      available_average < policy.hard_fastest_sec_per_rep ->
        {:error,
         %Infeasible{
           reason: :no_pace_within_hard_bounds,
           details: %{available_average: available_average},
           suggestions: ["Reduce reps", "Increase duration", "Remove explicit rest"]
         }}

      input.burpee_count_target == 1 ->
        one_rep_prescription(input, policy, available_average)

      true ->
        stream_prescription(input, policy, available_average)
    end
  end

  defp one_rep_prescription(input, policy, available_average) do
    sec_per_rep = min(preferred_midpoint(policy), available_average)

    if sec_per_rep < policy.hard_fastest_sec_per_rep or
         sec_per_rep > policy.hard_slowest_sec_per_rep do
      {:error,
       %Infeasible{
         reason: :no_pace_within_hard_bounds,
         details: %{sec_per_rep: sec_per_rep},
         suggestions: ["Adjust reps or duration"]
       }}
    else
      {:ok, prescription(input, policy, sec_per_rep, nil)}
    end
  end

  defp stream_prescription(input, policy, available_average) do
    sec_per_rep = min(preferred_midpoint(policy), available_average)
    explicit_rest_total = Enum.reduce(input.explicit_rests || [], 0, &(&1.duration_sec + &2))

    cadence_sec =
      (input.target_duration_sec - explicit_rest_total - sec_per_rep) /
        (input.burpee_count_target - 1)

    cond do
      cadence_sec < sec_per_rep ->
        {:error,
         %Infeasible{
           reason: :no_pace_within_hard_bounds,
           details: %{cadence_sec: cadence_sec, sec_per_rep: sec_per_rep},
           suggestions: ["Reduce reps", "Increase duration"]
         }}

      sec_per_rep > policy.hard_slowest_sec_per_rep ->
        {:error,
         %Infeasible{
           reason: :no_pace_within_hard_bounds,
           details: %{sec_per_rep: sec_per_rep},
           suggestions: ["Reduce duration or choose a faster target"]
         }}

      true ->
        {:ok, prescription(input, policy, sec_per_rep, cadence_sec)}
    end
  end

  defp prescription(input, policy, sec_per_rep, cadence_sec) do
    {:ok, block} = BlockSpec.new(1, [input.burpee_count_target])

    %Prescription{
      pacing_style: :even,
      burpee_type: input.burpee_type,
      target_duration_sec: input.target_duration_sec,
      burpee_count: input.burpee_count_target,
      sec_per_rep: sec_per_rep,
      cadence_sec: cadence_sec,
      blocks: [block],
      set_pattern: [input.burpee_count_target],
      recoveries: [],
      execution: nil,
      score: {0, 0, 0, 0, 0, 0, 0, 0, "even"},
      metadata: %{
        solver_version: 3,
        strategy: :even,
        pace_status: pace_status(sec_per_rep, policy),
        pace_policy: %{
          hard_fastest_sec_per_rep: policy.hard_fastest_sec_per_rep,
          preferred_fast_sec_per_rep: policy.preferred_fast_sec_per_rep,
          preferred_slow_sec_per_rep: policy.preferred_slow_sec_per_rep,
          hard_slowest_sec_per_rep: policy.hard_slowest_sec_per_rep
        }
      }
    }
  end

  defp preferred_midpoint(policy) do
    (policy.preferred_fast_sec_per_rep + policy.preferred_slow_sec_per_rep) / 2
  end

  defp pace_status(sec_per_rep, policy) do
    cond do
      sec_per_rep < policy.preferred_fast_sec_per_rep -> :too_fast
      sec_per_rep > policy.preferred_slow_sec_per_rep -> :too_slow
      true -> :comfortable
    end
  end
end
