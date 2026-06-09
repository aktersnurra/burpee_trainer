defmodule BurpeeTrainer.Planning.TimelineItem.MeaningfulPattern do
  @moduledoc "Repeated pattern that carries workout meaning, such as [4, 3]."
  @enforce_keys [:id, :start_sec, :repeat_count, :pattern]
  defstruct [:id, :start_sec, :repeat_count, :pattern, :unit_duration_sec]

  @type t :: %__MODULE__{
          id: String.t(),
          start_sec: non_neg_integer(),
          repeat_count: pos_integer(),
          pattern: [pos_integer()],
          unit_duration_sec: pos_integer() | nil
        }
end
