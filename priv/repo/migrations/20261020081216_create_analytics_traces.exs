defmodule BurpeeTrainer.Repo.Migrations.CreateAnalyticsTraces do
  use Ecto.Migration

  def change do
    create table(:analytics_traces, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :payload, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:analytics_traces, [:user_id, :expires_at])
  end
end
