defmodule BurpeeTrainer.Planning.TimelineItem.EvenUnit do
  @moduledoc "Even-pacing time unit where rest is distributed between reps."
  @enforce_keys [:id, :start_sec, :duration_sec, :reps]
  defstruct [:id, :start_sec, :duration_sec, :reps, :rep_interval_sec, :burpee_duration_sec]

  @type t :: %__MODULE__{
          id: String.t(),
          start_sec: non_neg_integer(),
          duration_sec: pos_integer(),
          reps: pos_integer(),
          rep_interval_sec: float() | nil,
          burpee_duration_sec: float() | nil
        }
end
