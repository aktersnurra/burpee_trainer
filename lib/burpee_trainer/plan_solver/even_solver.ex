defmodule BurpeeTrainer.PlanSolver.EvenSolver do
  @moduledoc "Plan Solver v3 even pacing branch."

  alias BurpeeTrainer.PlanSolver.{
    BlockSpec,
    ExplicitRest,
    Infeasible,
    PacePolicy,
    Prescription,
    Recovery
  }

  @spec solve(BurpeeTrainer.PlanSolver.Input.t(), PacePolicy.t()) ::
          {:ok, Prescription.t()} | {:error, Infeasible.t()}
  def solve(input, %PacePolicy{} = policy) do
    case input.burpee_count_target do
      1 -> one_rep_prescription(input, policy)
      _count -> multi_rep_prescription(input, policy)
    end
  end

  defp one_rep_prescription(input, policy) do
    cond do
      input.explicit_rests not in [nil, []] ->
        {:error, cannot_place_explicit_rest(input.explicit_rests)}

      input.target_duration_sec < policy.hard_fastest_sec_per_rep or
          input.target_duration_sec > policy.hard_slowest_sec_per_rep ->
        {:error, hard_bounds_infeasible(%{active_duration_sec: input.target_duration_sec})}

      true ->
        {blocks, set_pattern} = cadence_groups(input)
        p = input.target_duration_sec * 1.0

        {:ok, prescription(input, policy, p, p, blocks, set_pattern, [])}
    end
  end

  defp multi_rep_prescription(input, policy) do
    explicit_rest_total = Enum.sum_by(input.explicit_rests || [], & &1.duration_sec)
    active_budget = input.target_duration_sec - explicit_rest_total
    available_average = active_budget / input.burpee_count_target

    cond do
      available_average < policy.hard_fastest_sec_per_rep ->
        {:error, hard_bounds_infeasible(%{available_average: available_average})}

      true ->
        p = selected_movement_pace(input, policy, available_average)
        cadence_sec = (active_budget - p) / (input.burpee_count_target - 1)

        cond do
          p < policy.hard_fastest_sec_per_rep or p > policy.hard_slowest_sec_per_rep or
              cadence_sec < p ->
            {:error, hard_bounds_infeasible(%{cadence_sec: cadence_sec, sec_per_rep: p})}

          true ->
            {blocks, set_pattern} = cadence_groups(input)

            with {:ok, recoveries} <-
                   explicit_recoveries(input.explicit_rests || [], set_pattern, cadence_sec) do
              {:ok, prescription(input, policy, p, cadence_sec, blocks, set_pattern, recoveries)}
            end
        end
    end
  end

  defp prescription(input, policy, sec_per_rep, cadence_sec, blocks, set_pattern, recoveries) do
    %Prescription{
      pacing_style: :even,
      burpee_type: input.burpee_type,
      target_duration_sec: input.target_duration_sec,
      burpee_count: input.burpee_count_target,
      sec_per_rep: sec_per_rep,
      cadence_sec: cadence_sec,
      set_cadences: List.duplicate(cadence_sec, length(set_pattern)),
      blocks: blocks,
      set_pattern: set_pattern,
      recoveries: recoveries,
      execution: nil,
      score: {0, 0, 0, 0, 0, 0, 0, 0, "even"},
      metadata: %{
        solver_version: 3,
        strategy: :even,
        recommendation: "#{input.burpee_count_target} reps with even pace",
        pace_bias: input.pace_bias,
        load_shape: input.load_shape,
        rest_suggestions: [],
        recovery_mode: if(recoveries == [], do: :cadence, else: :explicit_rest),
        recovery_sec: 0.0,
        work_interval_sec: sec_per_rep,
        base_cadence_sec: cadence_sec,
        fastest_cadence_sec: cadence_sec,
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

  defp explicit_recoveries([], _set_pattern, _cadence_sec), do: {:ok, []}

  defp explicit_recoveries(rests, set_pattern, cadence_sec) do
    rests
    |> Enum.with_index()
    |> Enum.sort_by(fn {%ExplicitRest{} = rest, index} -> {rest.target_elapsed_sec, index} end)
    |> place_explicit_rests(set_pattern, cadence_sec, [])
    |> case do
      {:ok, recoveries} -> {:ok, recoveries}
      :error -> {:error, cannot_place_explicit_rest(rests)}
    end
  end

  defp place_explicit_rests([], _set_pattern, _cadence_sec, recoveries),
    do: {:ok, Enum.reverse(recoveries)}

  defp place_explicit_rests(
         [{%ExplicitRest{} = rest, _index} | remaining],
         set_pattern,
         cadence_sec,
         recoveries
       ) do
    previous_after_set = recoveries |> List.first() |> then(&if(&1, do: &1.after_set, else: 0))
    prior_rest_sec = Enum.sum_by(recoveries, & &1.total_sec)

    candidates =
      set_pattern
      |> Enum.with_index(1)
      |> Enum.drop(previous_after_set)
      |> Enum.drop(-1)
      |> Enum.map(fn {_reps, after_set} ->
        elapsed_sec = reps_through_set(set_pattern, after_set) * cadence_sec + prior_rest_sec
        %{after_set: after_set, elapsed_sec: elapsed_sec}
      end)
      |> Enum.filter(&(abs(&1.elapsed_sec - rest.target_elapsed_sec) <= rest.tolerance_sec))
      |> Enum.sort_by(&{abs(&1.elapsed_sec - rest.target_elapsed_sec), &1.after_set})

    Enum.reduce_while(candidates, :error, fn boundary, _result ->
      recovery = %Recovery{
        after_set: boundary.after_set,
        total_sec: rest.duration_sec,
        kind: :explicit,
        source: {:explicit, round(rest.target_elapsed_sec / 60)}
      }

      case place_explicit_rests(remaining, set_pattern, cadence_sec, [recovery | recoveries]) do
        {:ok, _recoveries} = result -> {:halt, result}
        :error -> {:cont, :error}
      end
    end)
  end

  defp cannot_place_explicit_rest(rests) do
    %Infeasible{
      reason: :cannot_place_explicit_rest,
      details: %{explicit_rests: rests},
      suggestions: ["Move the rest to an earlier set boundary", "Remove the explicit rest"]
    }
  end

  defp hard_bounds_infeasible(details) do
    %Infeasible{
      reason: :no_pace_within_hard_bounds,
      details: details,
      suggestions: ["Reduce reps", "Increase duration", "Remove explicit rest"]
    }
  end

  defp reps_through_set(set_pattern, after_set) do
    set_pattern
    |> Enum.take(after_set)
    |> Enum.sum()
  end

  defp cadence_groups(%{block_pattern: pattern, burpee_count_target: total_reps})
       when is_list(pattern) and pattern != [] do
    set_pattern = expand_block_pattern(total_reps, pattern)
    {block_specs_from_set_pattern(set_pattern), set_pattern}
  end

  defp cadence_groups(%{burpee_count_target: total_reps}) do
    {:ok, block} = BlockSpec.new(1, [total_reps])
    {[block], [total_reps]}
  end

  defp expand_block_pattern(total_reps, pattern) do
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
