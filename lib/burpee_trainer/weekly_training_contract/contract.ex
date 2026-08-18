defmodule BurpeeTrainer.WeeklyTrainingContract.Contract do
  @moduledoc "The fixed weekly training contract."

  alias BurpeeTrainer.WeeklyTrainingContract.Slot

  @type t :: %__MODULE__{
          target_sec: pos_integer(),
          target_min: pos_integer(),
          standard_session_duration_min: pos_integer(),
          slots: [Slot.t()]
        }

  defstruct target_sec: 4_800,
            target_min: 80,
            standard_session_duration_min: 20,
            slots: []
end
