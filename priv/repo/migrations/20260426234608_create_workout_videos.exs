defmodule BurpeeTrainer.Repo.Migrations.CreateWorkoutVideos do
  use Ecto.Migration

  def change do
    create table(:workout_videos) do
      add :name, :string, null: false
      add :filename, :string, null: false
      add :burpee_type, :string, null: false
      add :duration_sec, :integer, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:workout_videos, [:filename])
  end
end
