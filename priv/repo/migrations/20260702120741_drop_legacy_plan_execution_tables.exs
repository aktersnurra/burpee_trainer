defmodule BurpeeTrainer.Repo.Migrations.DropLegacyPlanExecutionTables do
  use Ecto.Migration

  def up do
    drop_if_exists table(:plan_steps)
    drop_if_exists table(:sets)
    drop_if_exists table(:blocks)

    alter table(:workout_plans) do
      remove :additional_rests
      remove :plan_solver_metadata
    end
  end

  def down do
    alter table(:workout_plans) do
      add :additional_rests, :text
      add :plan_solver_metadata, :map
    end

    create table(:blocks) do
      add :plan_id, references(:workout_plans, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :repeat_count, :integer, null: false, default: 1
      timestamps(type: :utc_datetime)
    end

    create table(:sets) do
      add :block_id, references(:blocks, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :burpee_count, :integer, null: false
      add :sec_per_rep, :float, null: false
      add :sec_per_burpee, :float, null: false, default: 3.0
      add :end_of_set_rest, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create table(:plan_steps) do
      add :plan_id, references(:workout_plans, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :kind, :string, null: false
      add :block_position, :integer
      add :repeat_count, :integer
      add :rest_sec, :integer
      timestamps(type: :utc_datetime)
    end
  end
end
