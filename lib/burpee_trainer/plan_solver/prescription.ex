defmodule BurpeeTrainer.PlanSolver.Prescription do
  @moduledoc "Canonical Plan Solver v3 output before persistence."

  alias BurpeeTrainer.PlanSolver.{BlockSpec, Recovery}

  @enforce_keys [
    :pacing_style,
    :burpee_type,
    :target_duration_sec,
    :burpee_count,
    :sec_per_rep,
    :blocks,
    :set_pattern,
    :recoveries,
    :score,
    :metadata
  ]
  defstruct [
    :pacing_style,
    :burpee_type,
    :target_duration_sec,
    :burpee_count,
    :sec_per_rep,
    :cadence_sec,
    :set_cadences,
    :blocks,
    :set_pattern,
    :recoveries,
    :execution,
    :score,
    :metadata
  ]

  @type t :: %__MODULE__{
          pacing_style: :even | :unbroken,
          burpee_type: :six_count | :navy_seal,
          target_duration_sec: pos_integer,
          burpee_count: pos_integer,
          sec_per_rep: float,
          cadence_sec: float | nil,
          set_cadences: [float] | nil,
          blocks: [BlockSpec.t()],
          set_pattern: [pos_integer],
          recoveries: [Recovery.t()],
          execution: list | nil,
          score: tuple,
          metadata: map
        }
end
