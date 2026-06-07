defmodule BurpeeTrainer.WeeklyTrainingContract.Contract do
  @moduledoc "The fixed weekly training contract."

  alias BurpeeTrainer.WeeklyTrainingContract.Slot

  @type t :: %__MODULE__{
          target_min: pos_integer(),
          standard_session_duration_min: pos_integer(),
          slots: [Slot.t()]
        }

  defstruct target_min: 80,
            standard_session_duration_min: 20,
            slots: []
end
