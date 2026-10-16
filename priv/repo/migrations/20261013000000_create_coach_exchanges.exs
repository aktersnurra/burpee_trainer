defmodule BurpeeTrainer.Repo.Migrations.CreateCoachExchanges do
  use Ecto.Migration

  # The owner's latest exchange with the coach: one row per user, replaced on each reply.
  def change do
    create table(:coach_exchanges) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :message, :text, null: false
      add :reply, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:coach_exchanges, [:user_id])
  end
end
