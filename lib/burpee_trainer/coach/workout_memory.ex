defmodule BurpeeTrainer.Coach.WorkoutMemory do
  use Ecto.Schema

  schema "coach_workout_memories" do
    field(:user_id, :integer)
    field(:workout_plan_id, :integer)
    field(:design_session_id, :integer)
    field(:facts, :map)
    field(:workout_reason, :map)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
