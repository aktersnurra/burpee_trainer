defmodule BurpeeTrainer.Workouts.PlanStep do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Workouts.WorkoutPlan

  @kinds [:block_run, :rest]

  @type t :: %__MODULE__{}

  schema "plan_steps" do
    field(:position, :integer)
    field(:kind, Ecto.Enum, values: @kinds)
    field(:block_position, :integer)
    field(:repeat_count, :integer)
    field(:rest_sec, :integer)

    belongs_to(:plan, WorkoutPlan)

    timestamps(type: :utc_datetime)
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [:position, :kind, :block_position, :repeat_count, :rest_sec])
    |> validate_required([:position, :kind])
    |> validate_number(:position, greater_than: 0)
    |> validate_by_kind()
  end

  defp validate_by_kind(changeset) do
    case get_field(changeset, :kind) do
      :block_run ->
        changeset
        |> validate_required([:block_position, :repeat_count])
        |> validate_number(:block_position, greater_than: 0)
        |> validate_number(:repeat_count, greater_than: 0)
        |> put_change(:rest_sec, nil)

      :rest ->
        changeset
        |> validate_required([:rest_sec])
        |> validate_number(:rest_sec, greater_than: 0)
        |> put_change(:block_position, nil)
        |> put_change(:repeat_count, nil)

      _ ->
        changeset
    end
  end
end
