defmodule BurpeeTrainer.Workouts.WorkoutPlan do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Accounts.User

  @burpee_types [:six_count, :navy_seal]
  @origins [:user, :coach, :built_in]
  @states [:draft, :published, :archived]

  @type t :: %__MODULE__{}

  schema "workout_plans" do
    field(:name, :string)
    field(:origin, Ecto.Enum, values: @origins)
    field(:state, Ecto.Enum, values: @states)
    field(:request_text, :string)
    field(:definition_json, :map)
    field(:program_json, :map)
    field(:content_hash, :string)
    field(:burpee_type, Ecto.Enum, values: @burpee_types)
    field(:target_reps, :integer)
    field(:target_duration_sec, :integer)
    field(:published_at, :utc_datetime)
    field(:archived_at, :utc_datetime)

    belongs_to(:user, User)

    timestamps(type: :utc_datetime_usec)
  end

  @spec burpee_types() :: [:six_count | :navy_seal]
  def burpee_types, do: @burpee_types

  @draft_content_fields [
    :name,
    :request_text,
    :definition_json,
    :program_json,
    :content_hash,
    :burpee_type,
    :target_reps,
    :target_duration_sec
  ]

  @doc false
  @spec new_draft_changeset(t(), map()) :: Ecto.Changeset.t()
  def new_draft_changeset(%__MODULE__{state: :draft} = plan, attrs) do
    draft_content_changeset(plan, attrs)
  end

  @doc false
  @spec replace_draft_changeset(t(), map()) :: Ecto.Changeset.t()
  def replace_draft_changeset(%__MODULE__{state: :draft} = plan, attrs) do
    plan
    |> draft_content_changeset(attrs)
    |> force_change(:updated_at, next_updated_at(plan.updated_at))
  end

  @doc false
  @spec publish_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def publish_changeset(%__MODULE__{state: :draft} = plan, %DateTime{} = published_at) do
    change(plan, state: :published, published_at: published_at)
  end

  @doc false
  @spec archive_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def archive_changeset(%__MODULE__{state: :published} = plan, %DateTime{} = archived_at) do
    change(plan, state: :archived, archived_at: archived_at)
  end

  defp next_updated_at(%DateTime{} = previous) do
    minimum = DateTime.add(previous, 1, :microsecond)
    now = DateTime.utc_now()

    if DateTime.compare(now, minimum) == :lt, do: minimum, else: now
  end

  defp draft_content_changeset(plan, attrs) do
    plan
    |> cast(attrs, @draft_content_fields)
    |> validate_required([
      :name,
      :definition_json,
      :program_json,
      :content_hash,
      :burpee_type,
      :target_reps,
      :target_duration_sec
    ])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_number(:target_reps, greater_than: 0)
    |> validate_number(:target_duration_sec, greater_than: 0)
  end
end
