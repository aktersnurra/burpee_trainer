defmodule BurpeeTrainer.Workouts.WorkoutSession do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Goals.Goal
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutVideo}

  @burpee_types [:six_count, :navy_seal]
  @valid_moods [-1, 0, 1]
  @primary_limiters [:breathing, :whole_body, :upper_body, :legs]
  @preference_feedback_values [:choose_again, :avoid]
  @feedback_fields [
    :context_low_energy,
    :context_high_energy,
    :context_heat_affected,
    :primary_limiter,
    :preference_feedback
  ]
  @type t :: %__MODULE__{}

  schema "workout_sessions" do
    field(:state, Ecto.Enum, values: [:started, :completed])
    field(:source_kind, Ecto.Enum, values: [:plan, :video, :manual])
    field(:display_name_snapshot, :string)
    field(:workout_type_snapshot, Ecto.Enum, values: @burpee_types)
    field(:program_snapshot, :map)
    field(:video_snapshot, :map)
    field(:content_hash, :string)
    field(:started_at, :utc_datetime)
    field(:completed_at, :utc_datetime)
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

    field(:context_low_energy, :boolean, default: false)
    field(:context_high_energy, :boolean, default: false)
    field(:context_heat_affected, :boolean, default: false)
    field(:primary_limiter, Ecto.Enum, values: @primary_limiters)
    field(:preference_feedback, Ecto.Enum, values: @preference_feedback_values)
    field(:prescribed_sets_completed, :integer)
    field(:reps_delta, :integer)
    field(:shortened, :boolean)
    field(:recovery_delta_sec, :integer)
    field(:pace_delta_sec, :float)
    field(:cadence_decline, :float)

    # Derived fields — computed by Workouts context at save time, never from user input.
    field(:style_name, :string)
    field(:rate_per_min_actual, :float)
    field(:days_since_last, :integer)
    field(:rate_delta, :float)
    field(:rate_avg_rolling_3, :float)
    field(:time_of_day_bucket, :string)

    belongs_to(:user, User)
    belongs_to(:plan, WorkoutPlan)

    belongs_to(:goal, Goal)
    belongs_to(:workout_video, WorkoutVideo)

    timestamps(type: :utc_datetime)
  end

  @spec burpee_types() :: [:six_count | :navy_seal]
  def burpee_types, do: @burpee_types

  @doc "Validates a fully snapshotted session before its initial started insert."
  @spec start_changeset(t()) :: Ecto.Changeset.t()
  def start_changeset(%__MODULE__{} = session) do
    session
    |> change()
    |> validate_required([
      :user_id,
      :state,
      :source_kind,
      :display_name_snapshot,
      :workout_type_snapshot,
      :content_hash,
      :client_session_id,
      :started_at,
      :burpee_type,
      :duration_sec_planned
    ])
    |> validate_client_session_id()
    |> unique_constraint(:client_session_id,
      name: :workout_sessions_user_id_client_session_id_index
    )
    |> apply_execution_constraints()
  end

  @doc "Validates the only mutable transition: started to completed."
  @spec completion_changeset(t(), map(), DateTime.t()) :: Ecto.Changeset.t()
  def completion_changeset(
        %__MODULE__{state: :started} = session,
        attrs,
        %DateTime{} = completed_at
      )
      when is_map(attrs) do
    session
    |> cast(attrs, [
      :burpee_count_actual,
      :duration_sec_actual,
      :note_pre,
      :note_post,
      :mood,
      :tags
      | @feedback_fields
    ])
    |> change(state: :completed, completed_at: DateTime.truncate(completed_at, :second))
    |> validate_session_core()
    |> validate_mood()
    |> validate_feedback_context()
    |> apply_execution_constraints()
  end

  @doc """
  Changeset for a direct completed/manual historical log. Identity and state
  are assigned by the context; callers provide the historical completion time.
  """
  @spec free_form_changeset(t(), map()) :: Ecto.Changeset.t()
  def free_form_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :burpee_type,
      :burpee_count_actual,
      :duration_sec_actual,
      :completed_at,
      :note_pre,
      :note_post,
      :mood,
      :tags
      | @feedback_fields
    ])
    |> validate_session_core()
    |> validate_required([:completed_at])
    |> validate_historical_completion()
    |> validate_mood()
    |> validate_feedback_context()
    |> apply_execution_constraints()
  end

  defp validate_session_core(changeset) do
    changeset
    |> validate_required([:burpee_type, :burpee_count_actual, :duration_sec_actual])
    |> validate_number(:burpee_count_actual, greater_than_or_equal_to: 0)
    |> validate_number(:duration_sec_actual, greater_than_or_equal_to: 0)
    |> validate_max_utf8_bytes(:note_pre, 500)
    |> validate_max_utf8_bytes(:note_post, 500)
  end

  defp validate_client_session_id(changeset) do
    validate_change(changeset, :client_session_id, fn :client_session_id, value ->
      if Ecto.UUID.cast(value) == {:ok, value},
        do: [],
        else: [client_session_id: "must be a UUID"]
    end)
  end

  defp validate_historical_completion(changeset) do
    case get_field(changeset, :completed_at) do
      %DateTime{} = completed_at ->
        if DateTime.compare(completed_at, DateTime.utc_now()) == :gt,
          do: add_error(changeset, :completed_at, "cannot be in the future"),
          else: changeset

      _missing_or_invalid ->
        changeset
    end
  end

  defp validate_mood(changeset) do
    case get_field(changeset, :mood) do
      nil -> changeset
      mood when mood in @valid_moods -> changeset
      _ -> add_error(changeset, :mood, "must be -1, 0, or 1")
    end
  end

  defp validate_feedback_context(changeset) do
    if get_field(changeset, :context_low_energy) and get_field(changeset, :context_high_energy) do
      add_error(changeset, :context_high_energy, "cannot be true when low energy is also true")
    else
      changeset
    end
  end

  defp apply_execution_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:plan_id)
    |> foreign_key_constraint(:workout_video_id)
    |> check_constraint(:state, name: :workout_sessions_source_snapshot_check)
    |> check_constraint(:content_hash, name: :workout_sessions_live_plan_snapshot_check)
    |> check_constraint(:content_hash, name: :workout_sessions_live_video_snapshot_check)
    |> check_constraint(:state, name: :workout_sessions_state_transition_check)
    |> check_constraint(:content_hash,
      name: :workout_sessions_identity_snapshot_immutable_check
    )
    |> check_constraint(:state, name: :workout_sessions_exact_once_completion_check)
    |> check_constraint(:context_high_energy, name: :workout_sessions_context_energy_check)
    |> check_constraint(:primary_limiter, name: :workout_sessions_primary_limiter_check)
    |> check_constraint(:preference_feedback, name: :workout_sessions_preference_feedback_check)
  end

  defp validate_max_utf8_bytes(changeset, field, max_bytes) do
    case get_field(changeset, field) do
      value when is_binary(value) ->
        cond do
          not String.valid?(value) ->
            add_error(changeset, field, "must be valid UTF-8")

          byte_size(value) > max_bytes ->
            add_error(changeset, field, "must be at most #{max_bytes} bytes")

          true ->
            changeset
        end

      _other ->
        changeset
    end
  end
end
