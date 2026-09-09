defmodule BurpeeTrainer.Repo.Migrations.AddCoachCatalogOrder do
  use Ecto.Migration

  def change do
    alter table(:coach_recommendations) do
      add :ranked_plan_ids, :map, null: false, default: %{}
    end
  end
end
