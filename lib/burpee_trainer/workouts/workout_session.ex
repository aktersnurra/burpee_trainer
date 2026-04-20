defmodule BurpeeTrainer.Workouts.WorkoutSession do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Workouts.WorkoutPlan

  @burpee_types [:six_count, :navy_seal]

  @type t :: %__MODULE__{}

  schema "workout_sessions" do
    field :burpee_type, Ecto.Enum, values: @burpee_types
    field :burpee_count_planned, :integer
    field :duration_sec_planned, :integer
    field :burpee_count_actual, :integer
    field :duration_sec_actual, :integer
    field :note_pre, :string
    field :note_post, :string

    belongs_to :user, User
    belongs_to :plan, WorkoutPlan

    timestamps(type: :utc_datetime)
  end

  def burpee_types, do: @burpee_types

  @doc """
  Changeset for a session completed from a plan. Planned values come
  from the plan; actuals come from the completion modal.

  `user_id` and `plan_id` are set by the context, not cast from attrs.
  """
  def from_plan_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :burpee_type,
      :burpee_count_planned,
      :duration_sec_planned,
      :burpee_count_actual,
      :duration_sec_actual,
      :note_pre,
      :note_post
    ])
    |> validate_session_core()
  end

  @doc """
  Changeset for a free-form session (no plan). Planned fields stay nil.
  """
  def free_form_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :burpee_type,
      :burpee_count_actual,
      :duration_sec_actual,
      :note_pre,
      :note_post,
      :inserted_at
    ])
    |> validate_session_core()
  end

  defp validate_session_core(changeset) do
    changeset
    |> validate_required([:burpee_type, :burpee_count_actual, :duration_sec_actual])
    |> validate_number(:burpee_count_actual, greater_than_or_equal_to: 0)
    |> validate_number(:duration_sec_actual, greater_than_or_equal_to: 0)
  end
end
