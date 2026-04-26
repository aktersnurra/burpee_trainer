defmodule BurpeeTrainer.PlanWizard do
  @moduledoc """
  Solver that converts a `%PlanInput{}` into a `%WorkoutPlan{}`.

  No Ecto, no side effects.

  Pacing styles:
    :even     — uniform cadence throughout. sec_per_rep = target_duration / total_reps.
                Rest is absorbed into the inter-rep gap; end_of_set_rest is always 0.
                With additional rests: cadence is uniformly shaved by
                total_rest_sec / total_reps so the total time is unchanged.
                Each rest is injected at the nearest rep boundary (within 30s).

    :unbroken — user-specified reps_per_set. Reps within a set are done
                continuously at sec_per_burpee (no inter-rep gap). Remaining
                time is distributed as end_of_set_rest between sets.
                Additional rests are injected at the nearest set boundary
                (within 30s).

  Physical pace floors (graduation landmark, max reps in 20 min):
    six_count:  sec_per_burpee >= 3.70s
    navy_seal:  sec_per_burpee >= 8.00s
  """

  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  defmodule PlanInput do
    @moduledoc false
    @enforce_keys [
      :name,
      :burpee_type,
      :target_duration_min,
      :burpee_count_target,
      :sec_per_burpee,
      :pacing_style
    ]
    defstruct [
      :name,
      :burpee_type,
      :target_duration_min,
      :burpee_count_target,
      :sec_per_burpee,
      :pacing_style,
      # :unbroken only — reps per set before resting; nil = use type default
      reps_per_set: nil,
      additional_rests: []
    ]
  end

  @sec_per_burpee_floor %{
    six_count: Float.ceil(1200 / 325, 2),
    navy_seal: 1200 / 150
  }

  @default_reps_per_set %{six_count: 10, navy_seal: 5}

  @doc """
  Validate pace against the physical floor for the given burpee type.
  Returns `:ok` or `{:error, :pace_too_fast, floor_value}`.
  """
  @spec validate_pace(atom, float) :: :ok | {:error, :pace_too_fast, float}
  def validate_pace(burpee_type, sec_per_burpee) do
    case Map.get(@sec_per_burpee_floor, burpee_type) do
      nil -> :ok
      floor when sec_per_burpee >= floor -> :ok
      floor -> {:error, :pace_too_fast, floor}
    end
  end

  @doc "Default reps-per-set for a given burpee type (:six_count or :navy_seal)."
  def default_reps_per_set(burpee_type), do: Map.get(@default_reps_per_set, burpee_type, 10)

  @doc """
  Generate a `%WorkoutPlan{}` from a `%PlanInput{}`.
  Returns `{:ok, plan}` or `{:error, [reason_string]}`.
  """
  @spec generate(PlanInput.t()) :: {:ok, WorkoutPlan.t()} | {:error, [String.t()]}
  def generate(%PlanInput{} = input) do
    with :ok <- check_pace(input) do
      case input.pacing_style do
        :even -> build_even(input)
        :unbroken -> build_unbroken(input)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp check_pace(%{burpee_type: t, sec_per_burpee: s}) do
    case validate_pace(t, s) do
      :ok ->
        :ok

      {:error, :pace_too_fast, floor} ->
        {:error,
         [
           "pace #{:erlang.float_to_binary(s * 1.0, decimals: 2)}s/rep is below the " <>
             "minimum #{:erlang.float_to_binary(floor * 1.0, decimals: 2)}s/rep for #{t} " <>
             "(graduation pace floor)"
         ]}
    end
  end

  # ---------------------------------------------------------------------------
  # Even pacing — uniform inter-rep cadence, no end-of-set rest
  # ---------------------------------------------------------------------------

  defp build_even(input) do
    target_sec = input.target_duration_min * 60
    base_cadence = target_sec / input.burpee_count_target

    cond do
      base_cadence < input.sec_per_burpee ->
        work = round(input.burpee_count_target * input.sec_per_burpee)

        {:error,
         [
           "work time (#{work}s) exceeds target duration (#{target_sec}s) — " <>
             "reduce reps or increase target duration"
         ]}

      input.additional_rests == [] ->
        set = %Set{
          position: 1,
          burpee_count: input.burpee_count_target,
          sec_per_rep: base_cadence,
          sec_per_burpee: input.sec_per_burpee,
          end_of_set_rest: 0
        }

        {:ok, wrap_plan(input, :even, [%Block{position: 1, repeat_count: 1, sets: [set]}])}

      true ->
        build_even_with_rests(input, base_cadence)
    end
  end

  # Even + additional rests: shave the cadence uniformly by total_rest/total_reps,
  # then inject rests at rep boundaries closest to each target_min.
  defp build_even_with_rests(input, base_cadence) do
    total_rest_sec = Enum.sum(for r <- input.additional_rests, do: r.rest_sec)
    shaved_cadence = base_cadence - total_rest_sec / input.burpee_count_target

    if shaved_cadence < input.sec_per_burpee do
      max_rest = Float.round((base_cadence - input.sec_per_burpee) * input.burpee_count_target, 1)

      {:error,
       [
         "total additional rest (#{total_rest_sec}s) requires cadence below " <>
           "#{:erlang.float_to_binary(input.sec_per_burpee * 1.0, decimals: 2)}s/rep floor — " <>
           "max #{max_rest}s additional rest for this pace and rep count"
       ]}
    else
      sorted_rests = Enum.sort_by(input.additional_rests, & &1.target_min)

      case find_even_splits(sorted_rests, shaved_cadence, input.burpee_count_target) do
        {:ok, split_points} ->
          blocks =
            build_even_segments(
              input.burpee_count_target,
              input.sec_per_burpee,
              shaved_cadence,
              split_points
            )

          {:ok, wrap_plan(input, :even, blocks)}

        {:error, _} = err ->
          err
      end
    end
  end

  # Find absolute rep-index split points for each rest, checking 30s tolerance.
  defp find_even_splits(sorted_rests, cadence, total_reps) do
    result =
      Enum.reduce_while(sorted_rests, {[], 0}, fn %{rest_sec: rest_sec, target_min: target_min},
                                                  {acc, prev_split} ->
        target_sec = target_min * 60.0
        ideal = round(target_sec / cadence)

        # Must split at a new position after the previous one, leaving at least 1 rep for the last segment
        split_at = ideal |> max(prev_split + 1) |> min(total_reps - 1)
        actual_time = split_at * cadence

        if abs(actual_time - target_sec) <= 30 do
          {:cont, {[{split_at, rest_sec} | acc], split_at}}
        else
          nearest_min = Float.round(actual_time / 60, 1)
          diff = round(abs(actual_time - target_sec))

          {:halt,
           {:error,
            [
              "cannot place rest at min #{target_min} — nearest rep boundary is at " <>
                "min #{nearest_min} (#{diff}s away, max 30s). Adjust your rep count or pace."
            ]}}
        end
      end)

    case result do
      {:error, _} = err -> err
      {splits, _} -> {:ok, Enum.reverse(splits)}
    end
  end

  # Build one block per segment. All blocks use the same shaved cadence.
  defp build_even_segments(total_reps, sec_per_burpee, cadence, split_points) do
    # split_points: [{abs_split_rep, rest_sec}, ...] — absolute rep index after which to rest
    # append a sentinel for the final segment (no trailing rest)
    all_splits = split_points ++ [{total_reps, 0}]

    {blocks, _, _} =
      Enum.reduce(all_splits, {[], 0, 1}, fn {split_at, rest_sec}, {blocks, prev, pos} ->
        reps = split_at - prev

        set = %Set{
          position: 1,
          burpee_count: reps,
          sec_per_rep: cadence,
          sec_per_burpee: sec_per_burpee,
          end_of_set_rest: rest_sec
        }

        block = %Block{position: pos, repeat_count: 1, sets: [set]}
        {[block | blocks], split_at, pos + 1}
      end)

    Enum.reverse(blocks)
  end

  # ---------------------------------------------------------------------------
  # Unbroken pacing — user-specified reps per set, rest fills remaining time
  # ---------------------------------------------------------------------------

  defp build_unbroken(input) do
    reps_per_set = input.reps_per_set || default_reps_per_set(input.burpee_type)

    if not is_integer(reps_per_set) or reps_per_set <= 0 do
      {:error, ["reps per set must be a positive integer"]}
    else
      actual_set_size = min(reps_per_set, input.burpee_count_target)
      build_unbroken_sets(input, actual_set_size)
    end
  end

  defp build_unbroken_sets(input, set_size) do
    target_sec = input.target_duration_min * 60
    total_work = input.burpee_count_target * input.sec_per_burpee
    total_add_rest = Enum.sum(for r <- input.additional_rests, do: r.rest_sec)
    total_between_rest = target_sec - total_work - total_add_rest

    cond do
      total_work > target_sec ->
        {:error,
         [
           "work time (#{round(total_work)}s) exceeds target duration (#{target_sec}s) — " <>
             "reduce reps or increase target duration"
         ]}

      total_between_rest < 0 ->
        {:error,
         [
           "work (#{round(total_work)}s) + additional rests (#{round(total_add_rest)}s) " <>
             "exceeds target duration (#{target_sec}s)"
         ]}

      true ->
        full_sets = div(input.burpee_count_target, set_size)
        remainder = rem(input.burpee_count_target, set_size)
        set_count = if remainder > 0, do: full_sets + 1, else: full_sets
        rest_per_gap = if set_count > 1, do: total_between_rest / (set_count - 1), else: 0.0

        sets =
          for i <- 0..(set_count - 1) do
            is_last = i == set_count - 1
            reps = if is_last and remainder > 0, do: remainder, else: set_size

            %Set{
              position: i + 1,
              burpee_count: reps,
              sec_per_rep: input.sec_per_burpee,
              sec_per_burpee: input.sec_per_burpee,
              end_of_set_rest: if(is_last, do: 0, else: round(rest_per_gap))
            }
          end

        inject_unbroken_rests(sets, input.additional_rests, input)
    end
  end

  # ---------------------------------------------------------------------------
  # Rest injection for unbroken (set boundaries)
  # ---------------------------------------------------------------------------

  defp inject_unbroken_rests(sets, [], input) do
    {:ok, wrap_plan(input, :unbroken, [%Block{position: 1, repeat_count: 1, sets: sets}])}
  end

  defp inject_unbroken_rests(sets, additional_rests, input) do
    set_count = length(sets)

    if set_count <= 1 do
      [%{target_min: t} | _] = additional_rests
      {:error, ["cannot place rest at min #{t} — only one set generated, adjust reps per set"]}
    else
      boundaries = build_set_boundaries(sets)

      case find_all_boundary_injections(boundaries, additional_rests) do
        {:ok, injections} ->
          new_sets = apply_injections(sets, injections)

          {:ok,
           wrap_plan(input, :unbroken, [%Block{position: 1, repeat_count: 1, sets: new_sets}])}

        {:error, _} = err ->
          err
      end
    end
  end

  defp build_set_boundaries(sets) do
    {times, _} =
      Enum.map_reduce(sets, 0.0, fn set, acc ->
        t = acc + set.burpee_count * set.sec_per_rep + set.end_of_set_rest
        {t, t}
      end)

    Enum.take(times, length(sets) - 1)
  end

  defp find_all_boundary_injections(boundaries, additional_rests) do
    Enum.reduce_while(additional_rests, {:ok, []}, fn
      %{rest_sec: rest_sec, target_min: target_min}, {:ok, acc} ->
        target_sec = target_min * 60.0

        case find_nearest_boundary(boundaries, target_sec, target_min) do
          {:ok, idx} -> {:cont, {:ok, [{idx, rest_sec} | acc]}}
          {:error, _} = err -> {:halt, err}
        end
    end)
  end

  defp find_nearest_boundary([], _target_sec, target_min) do
    {:error, ["no boundaries available for rest at min #{target_min}"]}
  end

  defp find_nearest_boundary(boundaries, target_sec, target_min) do
    {nearest_time, nearest_idx} =
      boundaries
      |> Enum.with_index()
      |> Enum.min_by(fn {t, _} -> abs(t - target_sec) end)

    if abs(nearest_time - target_sec) <= 30 do
      {:ok, nearest_idx}
    else
      nearest_min = Float.round(nearest_time / 60, 1)
      diff = round(abs(nearest_time - target_sec))

      {:error,
       [
         "cannot place rest at min #{target_min} — nearest set boundary is at " <>
           "min #{nearest_min} (#{diff}s away, max 30s). Adjust your reps per set."
       ]}
    end
  end

  defp apply_injections(sets, injections) do
    injection_map =
      Enum.reduce(injections, %{}, fn {idx, rest_sec}, acc ->
        Map.update(acc, idx, rest_sec, &(&1 + rest_sec))
      end)

    sets
    |> Enum.with_index()
    |> Enum.map(fn {set, i} ->
      case Map.fetch(injection_map, i) do
        {:ok, extra} -> %{set | end_of_set_rest: set.end_of_set_rest + extra}
        :error -> set
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp wrap_plan(input, style, blocks) do
    %WorkoutPlan{
      name: input.name,
      burpee_type: input.burpee_type,
      target_duration_min: input.target_duration_min,
      burpee_count_target: input.burpee_count_target,
      sec_per_burpee: input.sec_per_burpee,
      pacing_style: style,
      additional_rests: encode_rests(input.additional_rests),
      blocks: blocks
    }
  end

  defp encode_rests([]), do: "[]"

  defp encode_rests(rests) do
    items =
      Enum.map(rests, fn %{rest_sec: r, target_min: t} ->
        "{\"rest_sec\":#{r},\"target_min\":#{t}}"
      end)

    "[" <> Enum.join(items, ",") <> "]"
  end
end
