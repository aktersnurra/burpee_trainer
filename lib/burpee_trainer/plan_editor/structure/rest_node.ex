defmodule BurpeeTrainer.PlanEditor.Structure.RestNode do
  @moduledoc "A first-class explicit rest node between work nodes."

  @enforce_keys [:rest_sec]
  defstruct [:rest_sec]

  @type t :: %__MODULE__{rest_sec: pos_integer()}
end
