defmodule BurpeeTrainer.Repo.Migrations.CreateCoachGenerationAttempts do
  use Ecto.Migration

  def change do
    create table(:coach_generation_attempts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :event_key, :string, null: false
      add :status, :string, null: false
      add :attempt_count, :integer, null: false, default: 1
      add :last_attempted_at, :utc_datetime, null: false
      add :retry_after, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:coach_generation_attempts, [:user_id, :event_key])
    create index(:coach_generation_attempts, [:retry_after])
  end
end
