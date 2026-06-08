defmodule BurpeeTrainer.Repo.Migrations.CreatePlanSteps do
  use Ecto.Migration

  def change do
    create table(:plan_steps) do
      add :plan_id, references(:workout_plans, on_delete: :delete_all), null: false
      add :block_position, :integer
      add :position, :integer, null: false
      add :kind, :string, null: false
      add :repeat_count, :integer
      add :rest_sec, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:plan_steps, [:plan_id])
    create unique_index(:plan_steps, [:plan_id, :position])
  end
end
