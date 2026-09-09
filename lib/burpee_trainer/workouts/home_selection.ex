defmodule BurpeeTrainer.Workouts.HomeSelection do
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan}

  @enforce_keys [
    :recommendation_id,
    :home_revision,
    :plan,
    :recommendation_selection,
    :pending_draft_id
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          recommendation_id: pos_integer(),
          home_revision: non_neg_integer(),
          plan: WorkoutPlan.t(),
          recommendation_selection: CoachRecommendation.selection(),
          pending_draft_id: pos_integer() | nil
        }

  def new(r, plan) do
    selected =
      if r.selected_workout_plan_id,
        do: {:plan, r.selected_workout_plan_id},
        else: {:video, r.selected_workout_video_id}

    %__MODULE__{
      recommendation_id: r.id,
      home_revision: r.home_revision,
      plan: plan,
      recommendation_selection: selected,
      pending_draft_id: r.pending_draft_id
    }
  end
end
