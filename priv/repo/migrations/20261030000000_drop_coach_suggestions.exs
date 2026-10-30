defmodule BurpeeTrainer.Repo.Migrations.DropCoachSuggestions do
  use Ecto.Migration

  # The coach no longer predicts what the athlete might say next.
  def change do
    alter table(:coach_summaries) do
      remove :suggestions, :text, null: false, default: "[]"
    end

    alter table(:coach_exchanges) do
      remove :suggestions, :text, null: false, default: "[]"
    end
  end
end
