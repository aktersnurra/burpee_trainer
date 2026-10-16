defmodule BurpeeTrainer.Repo.Migrations.CoachExchangesKeepTheWeek do
  use Ecto.Migration

  # Every exchange is kept, so the coach on Home reads as a conversation, not one reply.
  def change do
    drop unique_index(:coach_exchanges, [:user_id])
    create index(:coach_exchanges, [:user_id, :inserted_at])
  end
end
