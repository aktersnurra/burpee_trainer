defmodule BurpeeTrainer.PlanWizard.Apply do
  @moduledoc """
  Collapses a solved `%SlotModel{}` into a persisted `%WorkoutPlan{}` of
  `%Block{}` and `%Set{}` records.

  ## What this module reads from the model

  Apply uses the *structural* output of the solver: which slots are
  reservations, the style label, `total_reps`, and `reps_per_set`. It does
  **not** read `slot_rests` numerically. Numeric set fields (`sec_per_rep`,
  `end_of_set_rest`) are derived directly from the original input via the
  same closed-form expressions the legacy procedural builder used.

  This split is deliberate: the slot-model rest distribution and the legacy
  cadence/end-of-set formulas both produce totals within ±1s of target, but
  *individual* values differ by ~0.07s for cadence (slot rests average over
  `total_reps − 1` slots while legacy cadence averages over `total_reps`).
  Existing regression tests in `test/burpee_trainer/plan_wizard_test.exs`
  assert `sec_per_rep` to ±1 ms and total duration to ±0.1s, so we keep the
  legacy formulas at the apply boundary. The slot model retains its value as
  the universal *structural* representation that decides *where* to split
  blocks and which set carries each reservation; it just doesn't drive the
  per-set scalars.

  ## Style → block/set rules

    * `:even` no reservations — one block, one set with all reps. Cadence is
      `target_sec / total_reps`. `end_of_set_rest = 0`.
    * `:even` with reservations — one block per (reservation + tail). Each
      non-final block has one set with `end_of_set_rest = reservation.rest_sec`.
      Cadence is `(target_sec − Σ reservation.rest_sec) / total_reps`,
      uniform across all segments.
    * `:unbroken` no reservations — one block with sets sized by
      `reps_per_set` (last set may be a partial). `sec_per_rep =
      sec_per_burpee`; `end_of_set_rest = round(rest_per_gap)` for non-final
      sets, where `rest_per_gap = (target_sec − work − Σ reservation.rest_sec)
      / (set_count − 1)`.
    * `:unbroken` with reservations — same as no-reservations, then each
      reservation's `rest_sec` is added to the `end_of_set_rest` of the set
      whose boundary slot matches the reservation. Reservations on the same
      set boundary stack.
  """

  alias BurpeeTrainer.PlanWizard.{PlanInput, SlotModel}
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  @spec to_workout_plan(SlotModel.t(), PlanInput.t()) :: {:ok, WorkoutPlan.t()}
  def to_workout_plan(%SlotModel{style: :even} = m, %PlanInput{} = input) do
    {:ok, wrap_plan(input, build_even(m, input))}
  end

  def to_workout_plan(%SlotModel{style: :unbroken} = m, %PlanInput{} = input) do
    {:ok, wrap_plan(input, build_unbroken(m, input))}
  end

  # ---------------------------------------------------------------------------
  # :even
  # ---------------------------------------------------------------------------

  defp build_even(%SlotModel{reservations: []} = m, input) do
    cadence = m.target_duration_sec / m.total_reps

    set = %Set{
      position: 1,
      burpee_count: m.total_reps,
      sec_per_rep: cadence,
      sec_per_burpee: input.sec_per_burpee,
      end_of_set_rest: 0
    }

    [%Block{position: 1, repeat_count: 1, sets: [set]}]
  end

  defp build_even(%SlotModel{} = m, input) do
    reservation_total = Enum.reduce(m.reservations, 0.0, fn r, acc -> acc + r.rest_sec end)
    cadence = (m.target_duration_sec - reservation_total) / m.total_reps

    sorted = Enum.sort_by(m.reservations, & &1.slot)
    splits = Enum.map(sorted, &{&1.slot, &1.rest_sec}) ++ [{m.total_reps, 0}]

    {blocks, _} =
      Enum.reduce(splits, {[], 0}, fn {split_at, rest_sec}, {acc, prev} ->
        reps = split_at - prev

        set = %Set{
          position: 1,
          burpee_count: reps,
          sec_per_rep: cadence,
          sec_per_burpee: input.sec_per_burpee,
          end_of_set_rest: rest_sec
        }

        block = %Block{position: length(acc) + 1, repeat_count: 1, sets: [set]}
        {[block | acc], split_at}
      end)

    Enum.reverse(blocks)
  end

  # ---------------------------------------------------------------------------
  # :unbroken
  # ---------------------------------------------------------------------------

  defp build_unbroken(%SlotModel{} = m, input) do
    set_size = min(m.reps_per_set, m.total_reps)
    full_sets = div(m.total_reps, set_size)
    remainder = rem(m.total_reps, set_size)
    set_count = if remainder > 0, do: full_sets + 1, else: full_sets

    reservation_total = Enum.reduce(m.reservations, 0.0, fn r, acc -> acc + r.rest_sec end)
    work = m.total_reps * input.sec_per_burpee
    between_rest_total = m.target_duration_sec - work - reservation_total

    rest_per_gap =
      if set_count > 1, do: between_rest_total / (set_count - 1), else: 0.0

    # Reservation slot S corresponds to "after rep S" → the set whose last
    # rep is rep S. With reps_per_set = k and full sets only, that is set
    # index `S / k` (1-indexed). Stack reservations that land on the same
    # set boundary.
    extra_by_set =
      Enum.reduce(m.reservations, %{}, fn r, acc ->
        idx = div(r.slot, set_size)
        Map.update(acc, idx, r.rest_sec, &(&1 + r.rest_sec))
      end)

    sets =
      for i <- 1..set_count do
        is_last = i == set_count
        reps = if is_last and remainder > 0, do: remainder, else: set_size
        base_rest = if is_last, do: 0, else: round(rest_per_gap)
        extra = Map.get(extra_by_set, i, 0)

        %Set{
          position: i,
          burpee_count: reps,
          sec_per_rep: input.sec_per_burpee,
          sec_per_burpee: input.sec_per_burpee,
          end_of_set_rest: base_rest + extra
        }
      end

    [%Block{position: 1, repeat_count: 1, sets: sets}]
  end

  # ---------------------------------------------------------------------------
  # Plan wrapper
  # ---------------------------------------------------------------------------

  defp wrap_plan(input, blocks) do
    %WorkoutPlan{
      name: input.name,
      burpee_type: input.burpee_type,
      target_duration_min: input.target_duration_min,
      burpee_count_target: input.burpee_count_target,
      sec_per_burpee: input.sec_per_burpee,
      pacing_style: input.pacing_style,
      additional_rests: encode_rests(input.additional_rests || []),
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
