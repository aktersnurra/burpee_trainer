defmodule BurpeeTrainer.PlanCompiler.ProgramEvent.Rest do
  @moduledoc "A rest instruction with concrete duration."

  @enforce_keys [:kind, :duration_sec]
  defstruct [:kind, :duration_sec]

  @type t :: %__MODULE__{
          kind: :rest,
          duration_sec: pos_integer() | float()
        }
end
