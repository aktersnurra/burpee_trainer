defmodule BurpeeTrainer.Workouts.Block do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Workouts.{Set, WorkoutPlan}

  @type t :: %__MODULE__{}

  schema "blocks" do
    field :position, :integer
    field :repeat_count, :integer, default: 1

    belongs_to :plan, WorkoutPlan
    has_many :sets, Set, preload_order: [asc: :position], on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def changeset(block, attrs) do
    block
    |> cast(attrs, [:position, :repeat_count])
    |> validate_required([:position, :repeat_count])
    |> validate_number(:position, greater_than: 0)
    |> validate_number(:repeat_count, greater_than: 0)
    |> cast_assoc(:sets,
      with: &Set.changeset/2,
      sort_param: :sets_sort,
      drop_param: :sets_drop,
      required: true
    )
  end
end
