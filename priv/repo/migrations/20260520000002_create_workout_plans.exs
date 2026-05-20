defmodule BurpeeTrainer.Repo.Migrations.CreateWorkoutPlans do
  use Ecto.Migration

  def change do
    create table(:workout_plans) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :burpee_type, :string, null: false
      add :style_name, :string
      add :target_duration_min, :integer
      add :burpee_count_target, :integer
      add :sec_per_burpee, :float
      add :pacing_style, :string
      add :additional_rests, :text
      add :fatigue_factor, :float, null: false, default: 0.0

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
      add :sec_per_rep, :float, null: false
      add :sec_per_burpee, :float, null: false, default: 3.0
      add :end_of_set_rest, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:sets, [:block_id])
    create unique_index(:sets, [:block_id, :position])
  end
end
