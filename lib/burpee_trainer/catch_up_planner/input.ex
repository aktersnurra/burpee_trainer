defmodule BurpeeTrainer.CatchUpPlanner.Input do
  @moduledoc "Input for type-locked catch-up planning."

  defstruct [
    :weekly_status,
    :remaining_slots,
    :selected_burpee_type,
    :performance_goal,
    :training_state,
    :history,
    :duration_min,
    :today
  ]
end
