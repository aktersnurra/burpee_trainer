defmodule BurpeeTrainer.PerformanceGoal do
  @moduledoc "A type-specific 20 minute performance goal."

  @type burpee_type :: :six_count | :navy_seal
  @type status :: :active | :paused | :completed

  @type t :: %__MODULE__{
          id: integer() | nil,
          burpee_type: burpee_type() | nil,
          target_reps: pos_integer() | nil,
          target_duration_min: pos_integer(),
          start_reps: non_neg_integer() | nil,
          start_date: Date.t() | nil,
          target_date: Date.t() | nil,
          status: status()
        }

  defstruct id: nil,
            burpee_type: nil,
            target_reps: nil,
            target_duration_min: 20,
            start_reps: nil,
            start_date: nil,
            target_date: nil,
            status: :active
end
