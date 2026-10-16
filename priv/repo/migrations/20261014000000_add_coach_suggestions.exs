defmodule BurpeeTrainer.Repo.Migrations.AddCoachSuggestions do
  use Ecto.Migration

  # What the athlete might say next, as the coach predicts it, kept with the note and reply.
  def change do
    alter table(:coach_summaries) do
      add :suggestions, :text, null: false, default: "[]"
    end

    alter table(:coach_exchanges) do
      add :suggestions, :text, null: false, default: "[]"
    end
  end
end
