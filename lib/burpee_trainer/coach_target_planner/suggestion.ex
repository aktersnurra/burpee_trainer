defmodule BurpeeTrainer.CoachTargetPlanner.Suggestion do
  @moduledoc "A coach target suggestion for one burpee type."

  defstruct [
    :kind,
    :title,
    :burpee_type,
    :burpee_count_target,
    :current_estimate_reps,
    :goal_reps,
    :status,
    :risk,
    :confidence,
    target_duration_min: 20,
    rationale: [],
    plan_input_defaults: %{pacing_style: :even, additional_rests: []}
  ]
end
