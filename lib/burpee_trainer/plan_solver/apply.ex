defmodule BurpeeTrainer.PlanSolver.Apply do
  @moduledoc """
  Collapses a solved pace `p` and set/rest patterns into a `%WorkoutPlan{}`.

  Additional rests are stored on the plan and rendered as timeline steps. They
  are not folded into set recovery.
  """

  alias BurpeeTrainer.PlanSolver.Input
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  @spec to_workout_plan(Input.t(), float, [float], [map]) :: {:ok, WorkoutPlan.t()}
  def to_workout_plan(%Input{pacing_style: :even} = input, p, _r, reservations) do
    to_workout_plan(input, p, [input.burpee_count_target], [], reservations)
  end

  def to_workout_plan(%Input{pacing_style: :unbroken} = input, p, _r, reservations) do
    set_pattern = legacy_unbroken_set_pattern(input)
    rest_pattern = legacy_unbroken_rest_pattern(input, p, set_pattern, reservations)
    to_workout_plan(input, p, set_pattern, rest_pattern, reservations)
  end

  @spec to_workout_plan(Input.t(), float, [pos_integer], [float], [map]) :: {:ok, WorkoutPlan.t()}
  def to_workout_plan(
        %Input{pacing_style: :even} = input,
        p,
        _set_pattern,
        _rest_pattern,
        reservations
      ) do
    {:ok, wrap_plan(input, p, build_even(input, p, reservations))}
  end

  def to_workout_plan(
        %Input{pacing_style: :unbroken} = input,
        p,
        set_pattern,
        rest_pattern,
        _reservations
      ) do
    {:ok, wrap_plan(input, p, build_unbroken(p, set_pattern, rest_pattern))}
  end

  # ---------------------------------------------------------------------------
  # :even
  # ---------------------------------------------------------------------------

  defp build_even(input, p, []) do
    target_sec = input.target_duration_min * 60.0
    n = input.burpee_count_target
    cadence = target_sec / n

    set = %Set{
      position: 1,
      burpee_count: n,
      sec_per_rep: cadence,
      sec_per_burpee: p,
      end_of_set_rest: 0
    }

    [%Block{position: 1, repeat_count: 1, sets: [set]}]
  end

  defp build_even(input, p, reservations) do
    target_sec = input.target_duration_min * 60.0
    n = input.burpee_count_target
    reservation_total = Enum.reduce(reservations, 0.0, fn r, acc -> acc + r.rest_sec end)
    cadence = (target_sec - reservation_total) / n

    sorted = Enum.sort_by(reservations, & &1.slot)
    splits = Enum.map(sorted, &{&1.slot, &1.rest_sec}) ++ [{n, 0}]

    {blocks, _} =
      Enum.reduce(splits, {[], 0}, fn {split_at, _rest_sec}, {acc, prev} ->
        reps = split_at - prev

        set = %Set{
          position: 1,
          burpee_count: reps,
          sec_per_rep: cadence,
          sec_per_burpee: p,
          end_of_set_rest: 0
        }

        block = %Block{position: length(acc) + 1, repeat_count: 1, sets: [set]}
        {[block | acc], split_at}
      end)

    Enum.reverse(blocks)
  end

  # ---------------------------------------------------------------------------
  # :unbroken
  # ---------------------------------------------------------------------------

  defp build_unbroken(p, set_pattern, rest_pattern) do
    sets =
      set_pattern
      |> Enum.with_index(1)
      |> Enum.map(fn {reps, i} ->
        base_rest = Enum.at(rest_pattern, i - 1, 0)

        %Set{
          position: i,
          burpee_count: reps,
          sec_per_rep: p,
          sec_per_burpee: p,
          end_of_set_rest: round(base_rest)
        }
      end)

    [%Block{position: 1, repeat_count: 1, sets: sets}]
  end

  defp legacy_unbroken_rest_pattern(input, p, set_pattern, reservations) do
    target_sec = input.target_duration_min * 60.0
    work_sec = input.burpee_count_target * p
    reservation_total = Enum.reduce(reservations, 0.0, fn r, acc -> acc + r.rest_sec end)
    gap_count = max(length(set_pattern) - 1, 0)

    if gap_count > 0 do
      rest_per_gap = max((target_sec - work_sec - reservation_total) / gap_count, 0.0)
      List.duplicate(rest_per_gap, gap_count)
    else
      []
    end
  end

  defp legacy_unbroken_set_pattern(input) do
    set_size = min(input.reps_per_set || 1, input.burpee_count_target)
    full_sets = div(input.burpee_count_target, set_size)
    remainder = rem(input.burpee_count_target, set_size)
    base = List.duplicate(set_size, full_sets)

    if remainder > 0, do: base ++ [remainder], else: base
  end

  # ---------------------------------------------------------------------------
  # Plan wrapper
  # ---------------------------------------------------------------------------

  defp wrap_plan(input, p, blocks) do
    %WorkoutPlan{
      name: input.name,
      burpee_type: input.burpee_type,
      target_duration_min: input.target_duration_min,
      burpee_count_target: input.burpee_count_target,
      sec_per_burpee: p,
      pacing_style: input.pacing_style,
      additional_rests: encode_rests(input.additional_rests || []),
      fatigue_factor: 0.0,
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
