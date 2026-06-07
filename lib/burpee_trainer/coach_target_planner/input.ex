defmodule BurpeeTrainer.CoachTargetPlanner.Input do
  @moduledoc "Input for a type-specific coach target request."

  defstruct [
    :goal,
    :history,
    :training_state,
    :weekly_status,
    :burpee_type,
    target_duration_min: 20,
    today: nil
  ]
end
