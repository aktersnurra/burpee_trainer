defmodule BurpeeTrainer.Workouts.WorkoutSession do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Goals.Goal
  alias BurpeeTrainer.Workouts.{ExecutionProgram, WorkoutPlan, WorkoutVideo}

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

    field(:status, Ecto.Enum,
      values: [:running, :report_pending, :reported, :aborted],
      default: :reported
    )

    field(:source, Ecto.Enum, values: [:plan, :video, :manual], default: :manual)
    field(:report_fingerprint, :string)
    field(:report_pending_at, :utc_datetime)
    field(:reported_at, :utc_datetime)
    field(:aborted_at, :utc_datetime)

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
    belongs_to(:video, WorkoutVideo)

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

  @doc """
  Changeset for a newly started session. Actual count and duration are captured
  only when the session is reported.
  """
  @spec start_changeset(t(), map()) :: Ecto.Changeset.t()
  def start_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :burpee_type,
      :burpee_count_planned,
      :duration_sec_planned,
      :note_pre,
      :source,
      :video_id,
      :client_session_id
    ])
    |> put_change(:status, :running)
    |> validate_required([:burpee_type, :source, :client_session_id])
    |> validate_inclusion(:status, [:running])
    |> validate_uuid(:client_session_id)
    |> unique_constraint(:user_id, name: :workout_sessions_one_unresolved_per_user_index)
    |> unique_constraint(:user_id, name: :workout_sessions_user_id_index)
  end

  @doc """
  Changeset for marking a running session ready for reporting.
  """
  @spec report_pending_changeset(t()) :: Ecto.Changeset.t()
  def report_pending_changeset(session) do
    change(session,
      status: :report_pending,
      report_pending_at: DateTime.utc_now(:second)
    )
  end

  @doc """
  Changeset for reporting a completed session.
  """
  @spec report_changeset(t(), map()) :: Ecto.Changeset.t()
  def report_changeset(session, attrs) do
    session
    |> cast(attrs, [:burpee_count_actual, :duration_sec_actual, :note_post, :mood, :tags])
    |> put_change(:status, :reported)
    |> put_change(:reported_at, DateTime.utc_now(:second))
    |> validate_session_core()
    |> validate_mood()
  end

  @doc """
  Changeset for aborting an in-progress session.
  """
  @spec abort_changeset(t()) :: Ecto.Changeset.t()
  def abort_changeset(session) do
    change(session,
      status: :aborted,
      aborted_at: DateTime.utc_now(:second)
    )
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

  defp validate_uuid(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case Ecto.UUID.cast(value) do
        {:ok, _uuid} -> []
        :error -> [{field, "must be a valid UUID"}]
      end
    end)
  end

  defp validate_mood(changeset) do
    case get_field(changeset, :mood) do
      nil -> changeset
      mood when mood in @valid_moods -> changeset
      _ -> add_error(changeset, :mood, "must be -1, 0, or 1")
    end
  end
end
