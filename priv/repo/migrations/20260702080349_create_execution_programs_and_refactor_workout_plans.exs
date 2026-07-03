defmodule BurpeeTrainer.Repo.Migrations.CreateExecutionProgramsAndRefactorWorkoutPlans do
  use Ecto.Migration

  def up do
    create table(:execution_programs) do
      add :content_hash, :string, null: false
      add :schema_version, :integer, null: false
      add :solver_version, :integer, null: false
      add :burpee_type, :string, null: false
      add :target_reps, :integer, null: false
      add :target_duration_sec, :integer, null: false
      add :event_count, :integer, null: false
      add :program_json, :map, null: false
      add :summary_json, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:execution_programs, [:content_hash])
    create index(:execution_programs, [:burpee_type])

    alter table(:workout_sessions) do
      add :execution_program_id, references(:execution_programs, on_delete: :nilify_all)
    end

    create index(:workout_sessions, [:execution_program_id])

    alter table(:workout_plans) do
      add :source_json, :map
      add :current_execution_program_id, references(:execution_programs, on_delete: :nilify_all)
    end

    create index(:workout_plans, [:current_execution_program_id])

    execute("DELETE FROM plan_steps")
    execute("DELETE FROM sets")
    execute("DELETE FROM blocks")
    execute("DELETE FROM workout_plans")
  end

  def down do
    alter table(:workout_plans) do
      remove :current_execution_program_id
      remove :source_json
    end

    alter table(:workout_sessions) do
      remove :execution_program_id
    end

    drop table(:execution_programs)
  end
end
