defmodule BurpeeTrainer.PlanCompiler.ProgramEvent.Work do
  @moduledoc "A work instruction containing reps with active and cadence timing."

  @enforce_keys [:kind, :reps, :sec_per_rep, :sec_per_burpee]
  defstruct [:kind, :reps, :sec_per_rep, :sec_per_burpee]

  @type t :: %__MODULE__{
          kind: :work,
          reps: pos_integer(),
          sec_per_rep: float(),
          sec_per_burpee: float()
        }
end
