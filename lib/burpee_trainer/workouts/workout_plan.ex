defmodule BurpeeTrainer.Workouts.WorkoutPlan do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Workouts.ExecutionProgram

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
    field(:style_name, :string)
    field(:fatigue_factor, :float, default: 0.0)
    field(:coach_suggestion_kind, :string)
    field(:coach_target_reps, :integer)
    field(:source_json, :map)

    # Transient editor projections derived from source/programs. These are not
    # persisted and must not be used as runtime execution truth.
    field(:blocks, :any, virtual: true, default: [])
    field(:steps, :any, virtual: true, default: [])
    field(:additional_rests, :string, virtual: true, default: "[]")
    field(:plan_solver_metadata, :map, virtual: true)

    belongs_to(:user, User)
    belongs_to(:current_execution_program, ExecutionProgram)

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
      :style_name,
      :fatigue_factor,
      :coach_suggestion_kind,
      :coach_target_reps,
      :source_json,
      :current_execution_program_id
    ])
    |> validate_required([:name, :source_json])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_number(:target_duration_min, greater_than: 0)
    |> validate_number(:burpee_count_target, greater_than: 0)
    |> validate_number(:sec_per_burpee, greater_than: 0)
    |> validate_number(:fatigue_factor,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
  end
end
