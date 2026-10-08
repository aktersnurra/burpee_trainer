defmodule BurpeeTrainer.Repo.Migrations.CreateSessionInsights do
  use Ecto.Migration

  def change do
    create table(:session_insights) do
      add :session_id, references(:workout_sessions, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :headline, :string, null: false
      add :points, :map, null: false
      add :source, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:session_insights, [:session_id])
    create index(:session_insights, [:user_id])
  end
end
