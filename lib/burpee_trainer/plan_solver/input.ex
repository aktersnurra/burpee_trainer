defmodule BurpeeTrainer.PlanSolver.Input do
  @moduledoc """
  Input to `BurpeeTrainer.PlanSolver.solve/1`. No `sec_per_burpee` —
  the solver finds the optimal pace from the level ceiling.
  """

  @enforce_keys [
    :name,
    :burpee_type,
    :target_duration_min,
    :burpee_count_target,
    :pacing_style,
    :level
  ]
  defstruct [
    :name,
    :burpee_type,
    :target_duration_min,
    :burpee_count_target,
    :pacing_style,
    :level,
    reps_per_set: nil,
    additional_rests: []
  ]

  @type burpee_type :: :six_count | :navy_seal
  @type pacing_style :: :even | :unbroken
  @type additional_rest :: %{rest_sec: number, target_min: number}
  @type level ::
          :level_1a
          | :level_1b
          | :level_1c
          | :level_1d
          | :level_2
          | :level_3
          | :level_4
          | :graduated

  @type t :: %__MODULE__{
          name: String.t(),
          burpee_type: burpee_type,
          target_duration_min: number,
          burpee_count_target: pos_integer,
          pacing_style: pacing_style,
          level: level,
          reps_per_set: pos_integer | nil,
          additional_rests: [additional_rest]
        }
end
