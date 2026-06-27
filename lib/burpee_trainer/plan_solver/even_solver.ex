defmodule BurpeeTrainer.PlanSolver.EvenSolver do
  @moduledoc "Plan Solver v3 even pacing branch."

  alias BurpeeTrainer.PlanSolver.{BlockSpec, Infeasible, PacePolicy, Prescription, Recovery}

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
    sec_per_rep = selected_movement_pace(input, policy, available_average)

    if sec_per_rep < policy.hard_fastest_sec_per_rep or
         sec_per_rep > policy.hard_slowest_sec_per_rep do
      {:error,
       %Infeasible{
         reason: :no_pace_within_hard_bounds,
         details: %{sec_per_rep: sec_per_rep},
         suggestions: ["Adjust reps or duration"]
       }}
    else
      cadence_sec = input.target_duration_sec / input.burpee_count_target

      with {:ok, recoveries} <- explicit_recoveries(input, cadence_sec) do
        {:ok, prescription(input, policy, sec_per_rep, cadence_sec, recoveries)}
      end
    end
  end

  defp stream_prescription(input, policy, available_average) do
    sec_per_rep = selected_movement_pace(input, policy, available_average)
    explicit_rest_total = Enum.reduce(input.explicit_rests || [], 0, &(&1.duration_sec + &2))

    cadence_sec = (input.target_duration_sec - explicit_rest_total) / input.burpee_count_target

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
        with {:ok, recoveries} <- explicit_recoveries(input, cadence_sec) do
          {:ok, prescription(input, policy, sec_per_rep, cadence_sec, recoveries)}
        end
    end
  end

  defp prescription(input, policy, sec_per_rep, cadence_sec, recoveries) do
    {blocks, set_pattern} = cadence_groups(input)

    %Prescription{
      pacing_style: :even,
      burpee_type: input.burpee_type,
      target_duration_sec: input.target_duration_sec,
      burpee_count: input.burpee_count_target,
      sec_per_rep: sec_per_rep,
      cadence_sec: cadence_sec,
      blocks: blocks,
      set_pattern: set_pattern,
      recoveries: recoveries,
      execution: nil,
      score: {0, 0, 0, 0, 0, 0, 0, 0, "even"},
      metadata: %{
        solver_version: 3,
        strategy: :even,
        recommendation: "#{input.burpee_count_target} reps with even cadence",
        rest_suggestions: [],
        recovery_mode: :cadence,
        recovery_sec: 0.0,
        work_interval_sec: sec_per_rep,
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

  defp explicit_recoveries(%{explicit_rests: rests}, _cadence_sec) when rests in [nil, []],
    do: {:ok, []}

  defp explicit_recoveries(input, cadence_sec) do
    {_blocks, set_pattern} = cadence_groups(input)
    boundaries = even_boundaries(set_pattern, cadence_sec)

    recoveries =
      Enum.reduce_while(input.explicit_rests || [], [], fn rest, acc ->
        case closest_boundary(boundaries, rest.target_elapsed_sec, rest.tolerance_sec) do
          nil ->
            {:halt,
             {:error,
              %Infeasible{
                reason: :cannot_place_explicit_rest,
                details: %{
                  target_elapsed_sec: rest.target_elapsed_sec,
                  duration_sec: rest.duration_sec
                },
                suggestions: [
                  "Move the rest to an earlier set boundary",
                  "Remove the explicit rest"
                ]
              }}}

          boundary ->
            recovery = %Recovery{
              after_set: boundary.after_set,
              total_sec: rest.duration_sec,
              kind: :explicit,
              source: {:explicit, round(rest.target_elapsed_sec / 60)}
            }

            {:cont, [recovery | acc]}
        end
      end)

    case recoveries do
      {:error, _error} = error -> error
      recoveries -> {:ok, Enum.reverse(recoveries)}
    end
  end

  defp even_boundaries(set_pattern, cadence_sec) do
    set_pattern
    |> Enum.drop(-1)
    |> Enum.with_index(1)
    |> Enum.map_reduce(0.0, fn {reps, after_set}, elapsed ->
      elapsed = elapsed + reps * cadence_sec
      {%{after_set: after_set, elapsed_sec: elapsed}, elapsed}
    end)
    |> elem(0)
  end

  defp closest_boundary(boundaries, target_elapsed_sec, tolerance_sec) do
    boundaries
    |> Enum.filter(&(abs(&1.elapsed_sec - target_elapsed_sec) <= tolerance_sec))
    |> Enum.min_by(&abs(&1.elapsed_sec - target_elapsed_sec), fn -> nil end)
  end

  defp cadence_groups(%{block_pattern: pattern, burpee_count_target: total_reps})
       when is_list(pattern) and pattern != [] do
    set_pattern = expand_legacy_pattern(total_reps, pattern)
    {block_specs_from_set_pattern(set_pattern), set_pattern}
  end

  defp cadence_groups(%{burpee_count_target: total_reps}) do
    {:ok, block} = BlockSpec.new(1, [total_reps])
    {[block], [total_reps]}
  end

  defp expand_legacy_pattern(total_reps, pattern) do
    {full_repeats, remainder_pattern} = split_pattern(total_reps, pattern)

    pattern
    |> List.duplicate(full_repeats)
    |> List.flatten()
    |> Kernel.++(remainder_pattern)
  end

  defp block_specs_from_set_pattern(set_pattern) do
    set_pattern
    |> Enum.chunk_every(2)
    |> Enum.chunk_by(& &1)
    |> Enum.map(fn same_motif_chunks ->
      motif = hd(same_motif_chunks)
      {:ok, block} = BlockSpec.new(length(same_motif_chunks), motif)
      block
    end)
  end

  defp split_pattern(total_reps, pattern) do
    block_total = Enum.sum(pattern)
    full_repeats = div(total_reps, block_total)
    remainder = rem(total_reps, block_total)

    remainder_pattern =
      if remainder > 0 do
        pattern
        |> Enum.reduce_while({[], remainder}, fn reps, {acc, remaining} ->
          cond do
            remaining == 0 -> {:halt, {acc, 0}}
            reps <= remaining -> {:cont, {acc ++ [reps], remaining - reps}}
            true -> {:halt, {acc ++ [remaining], 0}}
          end
        end)
        |> elem(0)
      else
        []
      end

    {full_repeats, remainder_pattern}
  end

  defp selected_movement_pace(%{sec_per_rep_override: override}, _policy, _available_average)
       when is_float(override),
       do: override

  defp selected_movement_pace(_input, policy, available_average) do
    min(preferred_midpoint(policy), available_average)
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
