defmodule BurpeeTrainer.PlanWizard.SlotModel do
  @moduledoc """
  Universal representation of a workout under construction.

  A workout is `total_reps` reps with `total_reps - 1` inter-rep slots. Every
  pacing style produces the same shape; only the slot weights differ.

  Fields:

    * `:total_reps`            — total burpee count (≥ 1).
    * `:sec_per_burpee`        — fixed movement time per rep.
    * `:target_duration_sec`   — target wall-clock duration.
    * `:style`                 — `:even | :unbroken` (pacing label).
    * `:reps_per_set`          — used by `:unbroken` weight pattern; nil otherwise.
    * `:weights`               — `[float]`, length `total_reps - 1`. Filled by
                                 `BurpeeTrainer.PlanWizard.Styles`.
    * `:reservations`          — `[%{slot: 1..total_reps-1, rest_sec: number,
                                      target_min: number}]`. Filled by the
                                 reservation solver.
    * `:slot_rests`            — `[float]`, length `total_reps - 1`. Filled by
                                 the continuous solver. `nil` until then.
    * `:additional_rests_input` — original input list, kept verbatim so the
                                  generated `%WorkoutPlan{}` round-trips it.
  """

  alias BurpeeTrainer.PlanWizard.{PlanInput, Styles}

  @enforce_keys [
    :total_reps,
    :sec_per_burpee,
    :target_duration_sec,
    :style,
    :weights,
    :additional_rests_input
  ]
  defstruct [
    :total_reps,
    :sec_per_burpee,
    :target_duration_sec,
    :style,
    :reps_per_set,
    :weights,
    :additional_rests_input,
    reservations: [],
    slot_rests: nil
  ]

  @type t :: %__MODULE__{
          total_reps: pos_integer,
          sec_per_burpee: number,
          target_duration_sec: number,
          style: Styles.style(),
          reps_per_set: pos_integer | nil,
          weights: [float],
          reservations: [%{slot: pos_integer, rest_sec: number, target_min: number}],
          slot_rests: [float] | nil,
          additional_rests_input: [PlanInput.additional_rest()]
        }

  @doc """
  Build a fresh `%SlotModel{}` from a `%PlanInput{}`. Computes the weight
  vector but does not solve — `:slot_rests` is `nil` and `:reservations` is
  `[]`.
  """
  @spec new(PlanInput.t(), pos_integer | nil) :: t
  def new(%PlanInput{} = input, reps_per_set) do
    %__MODULE__{
      total_reps: input.burpee_count_target,
      sec_per_burpee: input.sec_per_burpee,
      target_duration_sec: input.target_duration_min * 60,
      style: input.pacing_style,
      reps_per_set: reps_per_set,
      weights: Styles.weight_vector(input.pacing_style, input.burpee_count_target, reps_per_set),
      additional_rests_input: input.additional_rests || []
    }
  end

  @doc """
  Total movement time across all reps. Fixed for a given input.
  """
  @spec work_sec(t) :: float
  def work_sec(%__MODULE__{total_reps: r, sec_per_burpee: s}), do: r * s * 1.0

  @doc """
  Sum of additional-rest reservations the user requested (regardless of
  whether they have been placed yet).
  """
  @spec additional_rest_total(t) :: float
  def additional_rest_total(%__MODULE__{additional_rests_input: rests}) do
    Enum.reduce(rests, 0.0, fn r, acc -> acc + r.rest_sec end)
  end

  @doc """
  Rest budget available for the continuous solver to distribute across
  slots, after subtracting work time and reserved (additional) rest from the
  target duration. May be negative — feasibility is checked separately.
  """
  @spec rest_budget(t) :: float
  def rest_budget(%__MODULE__{} = m) do
    m.target_duration_sec - work_sec(m) - additional_rest_total(m)
  end
end
