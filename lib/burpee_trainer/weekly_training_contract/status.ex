defmodule BurpeeTrainer.WeeklyTrainingContract.Status do
  @moduledoc "Progress against the fixed weekly training contract."

  @type type_status :: %{
          target_sessions: non_neg_integer(),
          completed_standard_sessions: non_neg_integer(),
          completed_min: non_neg_integer(),
          remaining_standard_sessions: non_neg_integer()
        }

  @type status :: :empty | :in_progress | :complete | :under_target | :over_target | :non_standard

  @type t :: %__MODULE__{
          target_min: pos_integer(),
          completed_min: non_neg_integer(),
          remaining_min: non_neg_integer(),
          six_count: type_status(),
          navy_seal: type_status(),
          status: status()
        }

  defstruct target_min: 80,
            completed_min: 0,
            remaining_min: 80,
            six_count: %{},
            navy_seal: %{},
            status: :empty
end
