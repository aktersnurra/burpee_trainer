defmodule BurpeeTrainer.Repo.Migrations.AddWorkoutPlanApprovalKey do
  use Ecto.Migration

  def change do
    alter table(:workout_plans), do: add(:approval_key, :string)
    create unique_index(:workout_plans, [:approval_key])
  end
end
