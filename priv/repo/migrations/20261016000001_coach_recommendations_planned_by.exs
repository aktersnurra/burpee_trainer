defmodule BurpeeTrainer.Repo.Migrations.CoachRecommendationsPlannedBy do
  @moduledoc """
  Who chose a slot's workout: the owner on Home, Claude, or the in-app planner. Empty for
  the automatic first pick. The planner never replaces an owner's or Claude's choice.
  """
  use Ecto.Migration

  def change do
    alter table(:coach_recommendations) do
      add :planned_by, :string
    end
  end
end
