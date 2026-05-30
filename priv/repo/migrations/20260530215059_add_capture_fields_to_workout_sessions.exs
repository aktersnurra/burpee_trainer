defmodule BurpeeTrainer.Repo.Migrations.AddCaptureFieldsToWorkoutSessions do
  use Ecto.Migration

  def change do
    alter table(:workout_sessions) do
      add :capture_mode, :string, null: false, default: "logged"
      add :cadence_ms, :text
      add :target_pace_sec, :float
      add :pace_consistency, :float
    end

    create index(:workout_sessions, [:capture_mode])
  end
end
