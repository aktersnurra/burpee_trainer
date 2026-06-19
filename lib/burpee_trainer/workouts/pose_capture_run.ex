defmodule BurpeeTrainer.Workouts.PoseCaptureRun do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Workouts.{PoseTraceChunk, WorkoutPlan, WorkoutSession}

  @statuses [:active, :completed, :aborted]

  @type t :: %__MODULE__{}

  schema "pose_capture_runs" do
    field(:status, Ecto.Enum, values: @statuses, default: :active)
    field(:capture_version, :integer, default: 1)
    field(:started_at, :utc_datetime)
    field(:completed_at, :utc_datetime)
    field(:aborted_at, :utc_datetime)
    field(:abort_reason, :string)

    belongs_to(:user, User)
    belongs_to(:plan, WorkoutPlan)
    belongs_to(:workout_session, WorkoutSession)
    has_many(:pose_trace_chunks, PoseTraceChunk)

    timestamps(type: :utc_datetime)
  end

  @spec statuses() :: [:active | :completed | :aborted]
  def statuses, do: @statuses

  @spec start_changeset(t(), map()) :: Ecto.Changeset.t()
  def start_changeset(run, attrs) do
    run
    |> cast(attrs, [:capture_version, :started_at])
    |> validate_required([:user_id, :plan_id, :status, :capture_version, :started_at])
    |> validate_number(:capture_version, greater_than: 0)
  end

  @spec complete_changeset(t(), map()) :: Ecto.Changeset.t()
  def complete_changeset(run, attrs) do
    run
    |> cast(attrs, [:workout_session_id, :completed_at])
    |> change(status: :completed)
    |> validate_required([:workout_session_id, :completed_at])
  end

  @spec abort_changeset(t(), map()) :: Ecto.Changeset.t()
  def abort_changeset(run, attrs) do
    run
    |> cast(attrs, [:abort_reason, :aborted_at])
    |> change(status: :aborted)
    |> validate_required([:aborted_at])
  end
end
