defmodule BurpeeTrainer.PlanWizard.PlanInput do
  @moduledoc """
  Input to `BurpeeTrainer.PlanWizard.generate/1`.

  Pure data — no Ecto, no schema, no validation beyond `@enforce_keys`.
  Validation lives in the solver pipeline.
  """

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
    reps_per_set: nil,
    additional_rests: []
  ]

  @type burpee_type :: :six_count | :navy_seal
  @type pacing_style :: :even | :unbroken
  @type additional_rest :: %{rest_sec: number, target_min: number}

  @type t :: %__MODULE__{
          name: String.t(),
          burpee_type: burpee_type,
          target_duration_min: number,
          burpee_count_target: pos_integer,
          sec_per_burpee: number,
          pacing_style: pacing_style,
          reps_per_set: pos_integer | nil,
          additional_rests: [additional_rest]
        }
end
