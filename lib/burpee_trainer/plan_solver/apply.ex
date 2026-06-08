defmodule BurpeeTrainer.PlanSolver.Apply do
  @moduledoc """
  Collapses a solved pace `p` and reservation list into a `%WorkoutPlan{}`.

  `p` (solved pace, float) is passed as a separate argument.
  `fatigue_factor` is hardcoded to 0.0.
  """

  alias BurpeeTrainer.PlanSolver.Input
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  @spec to_workout_plan(Input.t(), float, [float], [map]) :: {:ok, WorkoutPlan.t()}
  def to_workout_plan(%Input{pacing_style: :even} = input, p, _r, reservations) do
    {:ok, wrap_plan(input, p, build_even(input, p, reservations))}
  end

  def to_workout_plan(%Input{pacing_style: :unbroken} = input, p, _r, reservations) do
    {:ok, wrap_plan(input, p, build_unbroken(input, p, reservations))}
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
      Enum.reduce(splits, {[], 0}, fn {split_at, rest_sec}, {acc, prev} ->
        reps = split_at - prev

        _additional_rest_sec = rest_sec

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

  defp build_unbroken(input, p, reservations) do
    target_sec = input.target_duration_min * 60.0
    n = input.burpee_count_target
    set_size = min(input.reps_per_set, n)
    full_sets = div(n, set_size)
    remainder = rem(n, set_size)
    set_count = if remainder > 0, do: full_sets + 1, else: full_sets

    reservation_total = Enum.reduce(reservations, 0.0, fn r, acc -> acc + r.rest_sec end)
    work = n * p
    between_rest_total = target_sec - work - reservation_total

    rest_per_gap =
      if set_count > 1, do: between_rest_total / (set_count - 1), else: 0.0

    sets =
      for i <- 1..set_count do
        is_last = i == set_count
        reps = if is_last and remainder > 0, do: remainder, else: set_size
        base_rest = if is_last, do: 0, else: round(rest_per_gap)

        %Set{
          position: i,
          burpee_count: reps,
          sec_per_rep: p,
          sec_per_burpee: p,
          end_of_set_rest: base_rest
        }
      end

    [%Block{position: 1, repeat_count: 1, sets: sets}]
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
