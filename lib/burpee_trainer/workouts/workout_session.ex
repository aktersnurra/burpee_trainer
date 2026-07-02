defmodule BurpeeTrainer.Workouts.WorkoutSession do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Goals.Goal
  alias BurpeeTrainer.Workouts.{ExecutionProgram, WorkoutPlan}

  @burpee_types [:six_count, :navy_seal]
  @valid_moods [-1, 0, 1]

  @type t :: %__MODULE__{}

  schema "workout_sessions" do
    field(:burpee_type, Ecto.Enum, values: @burpee_types)
    field(:burpee_count_planned, :integer)
    field(:duration_sec_planned, :integer)
    field(:burpee_count_actual, :integer)
    field(:duration_sec_actual, :integer)
    field(:note_pre, :string)
    field(:note_post, :string)
    field(:mood, :integer)
    field(:tags, :string)
    field(:capture_mode, Ecto.Enum, values: [:tracked, :timed, :logged], default: :logged)
    field(:cadence_ms, :string)
    field(:target_pace_sec, :float)
    field(:pace_consistency, :float)
    field(:client_session_id, :string)

    # Derived fields — computed by Workouts context at save time, never from user input.
    field(:style_name, :string)
    field(:rate_per_min_actual, :float)
    field(:days_since_last, :integer)
    field(:rate_delta, :float)
    field(:rate_avg_rolling_3, :float)
    field(:time_of_day_bucket, :string)

    belongs_to(:user, User)
    belongs_to(:plan, WorkoutPlan)
    belongs_to(:execution_program, ExecutionProgram)
    belongs_to(:goal, Goal)

    timestamps(type: :utc_datetime)
  end

  @spec burpee_types() :: [:six_count | :navy_seal]
  def burpee_types, do: @burpee_types

  @doc """
  Changeset for a session completed from a plan. Planned values come
  from the plan; actuals, mood, and tags come from the completion modal.

  `user_id` and `plan_id` are set by the context, not cast from attrs.
  Derived analytics fields are put directly on the changeset by the
  context after validation — they are never cast from user-supplied attrs.
  """
  @spec from_plan_changeset(t(), map()) :: Ecto.Changeset.t()
  def from_plan_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :burpee_type,
      :burpee_count_planned,
      :duration_sec_planned,
      :burpee_count_actual,
      :duration_sec_actual,
      :note_pre,
      :note_post,
      :mood,
      :tags,
      :client_session_id
    ])
    |> validate_session_core()
    |> validate_mood()
  end

  @doc """
  Changeset for a free-form session (no plan). Planned fields stay nil.
  """
  @spec free_form_changeset(t(), map()) :: Ecto.Changeset.t()
  def free_form_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :burpee_type,
      :burpee_count_actual,
      :duration_sec_actual,
      :note_pre,
      :note_post,
      :mood,
      :tags,
      :inserted_at,
      :client_session_id
    ])
    |> validate_session_core()
    |> validate_mood()
  end

  defp validate_session_core(changeset) do
    changeset
    |> validate_required([:burpee_type, :burpee_count_actual, :duration_sec_actual])
    |> validate_number(:burpee_count_actual, greater_than_or_equal_to: 0)
    |> validate_number(:duration_sec_actual, greater_than_or_equal_to: 0)
    |> unique_constraint(:client_session_id,
      name: :workout_sessions_user_id_client_session_id_index
    )
  end

  defp validate_mood(changeset) do
    case get_field(changeset, :mood) do
      nil -> changeset
      mood when mood in @valid_moods -> changeset
      _ -> add_error(changeset, :mood, "must be -1, 0, or 1")
    end
  end
end
