defmodule BurpeeTrainer.Repo.Migrations.AddAdaptiveHomeSelection do
  use Ecto.Migration

  def change do
    alter table(:coach_recommendations) do
      add :home_workout_plan_id, references(:workout_plans, on_delete: :nilify_all)
      add :home_revision, :integer, null: false, default: 0
    end

    create index(:coach_recommendations, [:home_workout_plan_id])
  end
end
