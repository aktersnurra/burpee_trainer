defmodule BurpeeTrainer.Repo.Migrations.AddCoachSummaryReview do
  use Ecto.Migration

  # The coach's look back over recent weeks, read at the top of Progress.
  def change do
    alter table(:coach_summaries) do
      add :review, :text
    end
  end
end
