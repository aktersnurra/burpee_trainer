defmodule BurpeeTrainer.Planning.TimelineItem.UnbrokenGroup do
  @moduledoc "Unbroken work group followed by recovery."
  @enforce_keys [:id, :start_sec, :reps, :burpee_duration_sec, :rest_after_sec]
  defstruct [:id, :start_sec, :reps, :burpee_duration_sec, :rest_after_sec]

  @type t :: %__MODULE__{
          id: String.t(),
          start_sec: non_neg_integer(),
          reps: pos_integer(),
          burpee_duration_sec: float(),
          rest_after_sec: non_neg_integer()
        }
end
