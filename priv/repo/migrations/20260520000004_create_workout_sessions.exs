defmodule BurpeeTrainer.Repo.Migrations.CreateWorkoutSessions do
  use Ecto.Migration

  def change do
    create table(:workout_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :plan_id, references(:workout_plans, on_delete: :nilify_all)
      add :goal_id, references(:goals, on_delete: :nilify_all)
      add :burpee_type, :string, null: false
      add :burpee_count_planned, :integer
      add :duration_sec_planned, :integer
      add :burpee_count_actual, :integer
      add :duration_sec_actual, :integer
      add :note_pre, :text
      add :note_post, :text
      add :mood, :integer
      add :tags, :text
      add :style_name, :string
      add :rate_per_min_actual, :float
      add :days_since_last, :integer
      add :rate_delta, :float
      add :rate_avg_rolling_3, :float
      add :time_of_day_bucket, :string

      timestamps(type: :utc_datetime)
    end

    create index(:workout_sessions, [:user_id])
    create index(:workout_sessions, [:user_id, :burpee_type])
    create index(:workout_sessions, [:user_id, :inserted_at])
    create index(:workout_sessions, [:goal_id])
  end
end
