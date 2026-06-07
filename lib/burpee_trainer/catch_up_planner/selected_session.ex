defmodule BurpeeTrainer.CatchUpPlanner.SelectedSession do
  @moduledoc "One selected session inside a catch-up plan."

  defstruct [
    :burpee_type,
    :duration_min,
    :target_reps,
    :suggestion_kind,
    :plan_input
  ]
end
