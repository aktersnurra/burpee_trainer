defmodule BurpeeTrainer.Workouts.WorkoutPlan do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Workouts.Block

  @burpee_types [:six_count, :navy_seal]
  @pacing_styles [:even, :unbroken]

  @type t :: %__MODULE__{}

  schema "workout_plans" do
    field :name, :string
    field :burpee_type, Ecto.Enum, values: @burpee_types
    field :target_duration_min, :integer
    field :burpee_count_target, :integer
    field :sec_per_burpee, :float
    field :pacing_style, Ecto.Enum, values: @pacing_styles
    field :additional_rests, :string, default: "[]"
    field :style_name, :string

    belongs_to :user, User

    has_many :blocks, Block,
      foreign_key: :plan_id,
      preload_order: [asc: :position],
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def burpee_types, do: @burpee_types

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :name,
      :burpee_type,
      :target_duration_min,
      :burpee_count_target,
      :sec_per_burpee,
      :pacing_style,
      :additional_rests,
      :style_name
    ])
    |> validate_required([:name, :burpee_type])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_number(:target_duration_min, greater_than: 0)
    |> validate_number(:burpee_count_target, greater_than: 0)
    |> validate_number(:sec_per_burpee, greater_than: 0)
    |> cast_assoc(:blocks,
      with: &Block.changeset/2,
      sort_param: :blocks_sort,
      drop_param: :blocks_drop,
      required: true
    )
  end
end
