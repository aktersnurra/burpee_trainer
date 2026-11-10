defmodule BurpeeTrainer.Repo.Migrations.IndexWorkoutSessionsCompletedAt do
  use Ecto.Migration

  # Home reads a user's completed sessions since a date (this week, the last six weeks).
  def change do
    create index(:workout_sessions, [:user_id, :state, :completed_at])
  end
end
