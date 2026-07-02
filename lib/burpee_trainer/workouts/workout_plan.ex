defmodule BurpeeTrainer.Workouts.WorkoutPlan do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Workouts.{Block, ExecutionProgram, PlanStep}

  @burpee_types [:six_count, :navy_seal]
  @pacing_styles [:even, :unbroken]

  @type t :: %__MODULE__{}

  schema "workout_plans" do
    field(:name, :string)
    field(:burpee_type, Ecto.Enum, values: @burpee_types)
    field(:target_duration_min, :integer)
    field(:burpee_count_target, :integer)
    field(:sec_per_burpee, :float)
    field(:pacing_style, Ecto.Enum, values: @pacing_styles)
    field(:additional_rests, :string, default: "[]")
    field(:style_name, :string)
    field(:fatigue_factor, :float, default: 0.0)
    field(:coach_suggestion_kind, :string)
    field(:coach_target_reps, :integer)
    field(:plan_solver_metadata, :map)
    field(:source_json, :map)

    belongs_to(:user, User)
    belongs_to(:current_execution_program, ExecutionProgram)

    has_many(:blocks, Block,
      foreign_key: :plan_id,
      preload_order: [asc: :position],
      on_replace: :delete
    )

    has_many(:steps, PlanStep,
      foreign_key: :plan_id,
      preload_order: [asc: :position],
      on_replace: :delete
    )

    timestamps(type: :utc_datetime)
  end

  @spec burpee_types() :: [:six_count | :navy_seal]
  def burpee_types, do: @burpee_types

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
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
      :style_name,
      :fatigue_factor,
      :coach_suggestion_kind,
      :coach_target_reps,
      :plan_solver_metadata,
      :source_json,
      :current_execution_program_id
    ])
    |> validate_required([:name, :burpee_type])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_number(:target_duration_min, greater_than: 0)
    |> validate_number(:burpee_count_target, greater_than: 0)
    |> validate_number(:sec_per_burpee, greater_than: 0)
    |> validate_number(:fatigue_factor,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> cast_assoc(:blocks,
      with: &Block.changeset/2,
      sort_param: :blocks_sort,
      drop_param: :blocks_drop,
      required: true
    )
    |> cast_assoc(:steps,
      with: &PlanStep.changeset/2,
      sort_param: :steps_sort,
      drop_param: :steps_drop
    )
  end
end
