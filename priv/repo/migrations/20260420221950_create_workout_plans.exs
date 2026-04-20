defmodule BurpeeTrainer.Repo.Migrations.CreateWorkoutPlans do
  use Ecto.Migration

  def change do
    create table(:workout_plans) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :burpee_type, :string, null: false
      add :warmup_enabled, :boolean, null: false, default: false
      add :warmup_reps, :integer
      add :warmup_rounds, :integer
      add :rest_sec_warmup_between, :integer, null: false, default: 120
      add :rest_sec_warmup_before_main, :integer, null: false, default: 180
      add :shave_off_sec, :integer
      add :shave_off_block_count, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:workout_plans, [:user_id])

    create table(:blocks) do
      add :plan_id, references(:workout_plans, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :repeat_count, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:blocks, [:plan_id])
    create unique_index(:blocks, [:plan_id, :position])

    create table(:sets) do
      add :block_id, references(:blocks, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :burpee_count, :integer, null: false
      add :sec_per_burpee, :float, null: false
      add :rest_sec_after_set, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:sets, [:block_id])
    create unique_index(:sets, [:block_id, :position])
  end
end
