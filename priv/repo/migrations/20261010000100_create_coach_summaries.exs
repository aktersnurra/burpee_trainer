defmodule BurpeeTrainer.Repo.Migrations.CreateCoachSummaries do
  use Ecto.Migration

  def change do
    create table(:coach_summaries) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :text, :text, null: false
      add :metric_ids, :text, null: false
      add :source, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:coach_summaries, [:user_id])
  end
end
