defmodule BurpeeTrainer.Coach.DesignSession do
  use Ecto.Schema
  @type t :: %__MODULE__{}
  schema "workout_design_sessions" do
    field :user_id, :integer
    field :workspace_key, :string
    field :source_plan_id, :integer
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
