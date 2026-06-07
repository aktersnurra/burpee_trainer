defmodule BurpeeTrainer.WeeklyTrainingContract.Slot do
  @moduledoc "A canonical weekly training slot."

  @type burpee_type :: :six_count | :navy_seal
  @type t :: %__MODULE__{burpee_type: burpee_type(), duration_min: pos_integer()}

  defstruct [:burpee_type, :duration_min]
end
