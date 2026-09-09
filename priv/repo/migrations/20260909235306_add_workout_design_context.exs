defmodule BurpeeTrainer.Repo.Migrations.AddWorkoutDesignContext do
  use Ecto.Migration

  def change do
    create table(:workout_design_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :workspace_key, :string, null: false
      add :source_plan_id, :integer
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:workout_design_sessions, [:user_id, :workspace_key])

    create table(:workout_design_entries) do
      add :design_session_id, references(:workout_design_sessions, on_delete: :delete_all),
        null: false

      add :attempt_id, :uuid, null: false
      add :kind, :string, null: false
      add :payload, :map, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:workout_design_entries, [:design_session_id, :id])
    create unique_index(:workout_design_entries, [:design_session_id, :attempt_id, :kind])

    alter table(:workout_plans) do
      add :design_session_id, references(:workout_design_sessions, on_delete: :nilify_all)
    end

    create table(:coach_settings) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :settings, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:coach_settings, [:user_id])

    create table(:coach_workout_memories) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :workout_plan_id, :integer, null: false
      add :design_session_id, :integer
      add :facts, :map, null: false
      add :workout_reason, :map, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:coach_workout_memories, [:user_id, :workout_plan_id])

    execute(
      """
      CREATE TRIGGER workout_design_entries_no_update
      BEFORE UPDATE ON workout_design_entries
      BEGIN SELECT RAISE(ABORT, 'design_entries_append_only'); END
      """,
      "DROP TRIGGER workout_design_entries_no_update"
    )
  end
end
