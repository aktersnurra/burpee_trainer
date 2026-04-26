defmodule BurpeeTrainer.Workouts.WorkoutVideo do
  use Ecto.Schema
  import Ecto.Changeset

  schema "workout_videos" do
    field :name, :string
    field :filename, :string
    field :burpee_type, Ecto.Enum, values: [:six_count, :navy_seal]
    field :duration_sec, :integer

    timestamps(updated_at: false)
  end

  def changeset(video, attrs) do
    video
    |> cast(attrs, [:name, :filename, :burpee_type, :duration_sec])
    |> validate_required([:name, :filename, :burpee_type, :duration_sec])
    |> validate_number(:duration_sec, greater_than: 0)
    |> unique_constraint(:filename)
  end
end
