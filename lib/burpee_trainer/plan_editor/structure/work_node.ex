defmodule BurpeeTrainer.PlanEditor.Structure.WorkNode do
  @moduledoc "A user-editable work node: repeat a Block pattern N times."

  @enforce_keys [:repeat_count, :set_pattern]
  defstruct [:repeat_count, :set_pattern]

  @type t :: %__MODULE__{repeat_count: pos_integer(), set_pattern: [pos_integer()]}
end
