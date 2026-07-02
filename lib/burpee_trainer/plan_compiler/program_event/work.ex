defmodule BurpeeTrainer.PlanCompiler.ProgramEvent.Work do
  @moduledoc "A work instruction containing reps at a concrete cadence."

  @enforce_keys [:kind, :reps, :sec_per_rep]
  defstruct [:kind, :reps, :sec_per_rep]

  @type t :: %__MODULE__{
          kind: :work,
          reps: pos_integer(),
          sec_per_rep: float()
        }
end
