defmodule BurpeeTrainer.Workouts.CoachRecommendation do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutVideo}

  @type t :: %__MODULE__{}
  @type selection :: {:plan, pos_integer()} | {:video, pos_integer()}

  schema "coach_recommendations" do
    field(:slot_key, :string)
    field(:slot_date, :date)
    field(:rationale, :string)

    belongs_to(:user, User)
    belongs_to(:selected_workout_plan, WorkoutPlan)
    belongs_to(:selected_workout_video, WorkoutVideo)
    belongs_to(:pending_draft, WorkoutPlan)

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(recommendation, attrs) do
    recommendation
    |> cast(attrs, [
      :slot_key,
      :slot_date,
      :rationale,
      :selected_workout_plan_id,
      :selected_workout_video_id,
      :pending_draft_id
    ])
    |> validate_required([:user_id, :slot_key, :slot_date])
    |> validate_selection()
    |> unique_constraint([:user_id, :slot_key],
      name: :coach_recommendations_user_id_slot_key_index
    )
    |> foreign_key_constraint(:selected_workout_plan_id)
    |> foreign_key_constraint(:selected_workout_video_id)
    |> foreign_key_constraint(:pending_draft_id)
    |> check_constraint(:selected_workout_plan_id,
      name: :coach_recommendations_selection_check
    )
  end

  @spec selection_changeset(t(), map()) :: Ecto.Changeset.t()
  def selection_changeset(recommendation, attrs) do
    recommendation
    |> cast(attrs, [:selected_workout_plan_id, :selected_workout_video_id, :rationale])
    |> validate_selection()
    |> foreign_key_constraint(:selected_workout_plan_id)
    |> foreign_key_constraint(:selected_workout_video_id)
    |> check_constraint(:selected_workout_plan_id,
      name: :coach_recommendations_selection_check
    )
  end

  @spec candidate_changeset(t(), map()) :: Ecto.Changeset.t()
  def candidate_changeset(recommendation, attrs) do
    recommendation
    |> cast(attrs, [:pending_draft_id])
    |> foreign_key_constraint(:pending_draft_id)
  end

  defp validate_selection(changeset) do
    plan_id = get_field(changeset, :selected_workout_plan_id)
    video_id = get_field(changeset, :selected_workout_video_id)

    if (positive_integer?(plan_id) and is_nil(video_id)) or
         (is_nil(plan_id) and positive_integer?(video_id)) do
      changeset
    else
      add_error(changeset, :selected_workout_plan_id, "must select exactly one plan or video")
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
