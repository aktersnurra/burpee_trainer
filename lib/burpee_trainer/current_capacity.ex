defmodule BurpeeTrainer.CurrentCapacity do
  @moduledoc "A type-specific current capacity estimate."

  @type burpee_type :: :six_count | :navy_seal
  @type trend :: :improving | :flat | :declining | :unknown

  @type t :: %__MODULE__{
          burpee_type: burpee_type(),
          duration_min: pos_integer(),
          estimated_reps: non_neg_integer(),
          recent_best_reps: non_neg_integer() | nil,
          recent_completed_avg_reps: float() | nil,
          last_successful_reps: non_neg_integer() | nil,
          trend: trend(),
          confidence: float()
        }

  defstruct [
    :burpee_type,
    duration_min: 20,
    estimated_reps: 0,
    recent_best_reps: nil,
    recent_completed_avg_reps: nil,
    last_successful_reps: nil,
    trend: :unknown,
    confidence: 0.0
  ]
end
