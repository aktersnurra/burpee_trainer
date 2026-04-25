defmodule BurpeeTrainer.Repo.Migrations.AddStyleNameToWorkoutPlans do
  use Ecto.Migration

  def change do
    alter table(:workout_plans) do
      add :style_name, :string
    end
  end
end
