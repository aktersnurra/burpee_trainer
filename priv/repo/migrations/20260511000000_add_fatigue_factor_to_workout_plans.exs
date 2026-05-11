defmodule BurpeeTrainer.Repo.Migrations.AddFatigueFactorToWorkoutPlans do
  use Ecto.Migration

  def change do
    alter table(:workout_plans) do
      add :fatigue_factor, :float, default: 0.0, null: false
    end
  end
end
