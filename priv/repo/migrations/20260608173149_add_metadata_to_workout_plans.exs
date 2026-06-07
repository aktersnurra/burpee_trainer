defmodule BurpeeTrainer.Repo.Migrations.AddMetadataToWorkoutPlans do
  use Ecto.Migration

  def change do
    alter table(:workout_plans) do
      add :coach_suggestion_kind, :string
      add :coach_target_reps, :integer
      add :plan_solver_metadata, :map
    end
  end
end
