defmodule BurpeeTrainer.PlanCompiler.ProgramEvent.Work do
  @moduledoc "A work instruction containing reps at a concrete cadence."

  @enforce_keys [:id, :kind, :set_index, :reps, :duration_sec, :sec_per_rep, :label]
  defstruct [
    :id,
    :kind,
    :set_index,
    :block_index,
    :display_group,
    :reps,
    :duration_sec,
    :sec_per_rep,
    :label
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: :work,
          set_index: pos_integer(),
          block_index: pos_integer() | nil,
          display_group: String.t() | nil,
          reps: pos_integer(),
          duration_sec: float(),
          sec_per_rep: float(),
          label: String.t()
        }
end
