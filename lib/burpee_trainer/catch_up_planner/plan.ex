defmodule BurpeeTrainer.CatchUpPlanner.Plan do
  @moduledoc "A type-locked catch-up plan."

  defstruct [
    :selected_burpee_type,
    :total_duration_min,
    selected_sessions: [],
    expected_progress_value: 0.0,
    fatigue_cost: 0.0,
    risk: :normal,
    canonical?: false,
    weekly_split_effect: :counts_but_non_standard,
    rationale: [],
    metadata: %{}
  ]
end
