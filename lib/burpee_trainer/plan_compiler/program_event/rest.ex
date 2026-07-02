defmodule BurpeeTrainer.PlanCompiler.ProgramEvent.Rest do
  @moduledoc "A rest instruction with concrete duration."

  @enforce_keys [:id, :kind, :duration_sec, :label]
  defstruct [:id, :kind, :duration_sec, :label, :source]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: :rest,
          duration_sec: pos_integer() | float(),
          label: String.t(),
          source: atom() | tuple() | nil
        }
end
