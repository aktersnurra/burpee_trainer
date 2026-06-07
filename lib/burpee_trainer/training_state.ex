defmodule BurpeeTrainer.TrainingState do
  @moduledoc "Type-specific training state used by coach planning."

  alias BurpeeTrainer.CurrentCapacity

  @type fatigue :: :low | :normal | :high | :unknown

  @type t :: %__MODULE__{
          level_by_type: %{six_count: atom(), navy_seal: atom()},
          current_capacity_by_type: %{
            six_count: CurrentCapacity.t(),
            navy_seal: CurrentCapacity.t()
          },
          fatigue: fatigue(),
          recent_completion_rate: float(),
          recent_missed_sessions: non_neg_integer(),
          confidence: float()
        }

  defstruct level_by_type: %{six_count: :level_1c, navy_seal: :level_1c},
            current_capacity_by_type: %{},
            fatigue: :unknown,
            recent_completion_rate: 0.0,
            recent_missed_sessions: 0,
            confidence: 0.0
end
