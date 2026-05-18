defmodule BurpeeTrainer.Repo.Migrations.CreateUserStats do
  use Ecto.Migration

  def change do
    create table(:user_stats, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), primary_key: true
      add :previous_best_weeks, :integer, null: false, default: 0
      # ISO date string, nullable
      add :previous_best_ended_on, :string

      timestamps(updated_at: true, inserted_at: false)
    end
  end
end
