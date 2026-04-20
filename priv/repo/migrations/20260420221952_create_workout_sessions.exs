defmodule BurpeeTrainer.Repo.Migrations.CreateWorkoutSessions do
  use Ecto.Migration

  def change do
    create table(:workout_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :plan_id, references(:workout_plans, on_delete: :nilify_all)
      add :burpee_type, :string, null: false
      add :burpee_count_planned, :integer
      add :duration_sec_planned, :integer
      add :burpee_count_actual, :integer, null: false
      add :duration_sec_actual, :integer, null: false
      add :note_pre, :text
      add :note_post, :text

      timestamps(type: :utc_datetime)
    end

    create index(:workout_sessions, [:user_id])
    create index(:workout_sessions, [:user_id, :burpee_type])
    create index(:workout_sessions, [:user_id, :inserted_at])
  end
end
