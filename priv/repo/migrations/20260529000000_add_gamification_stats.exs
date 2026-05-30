defmodule BurpeeTrainer.Repo.Migrations.AddGamificationStats do
  use Ecto.Migration

  def change do
    alter table(:user_stats) do
      add :best_week_pushups, :integer, null: false, default: 0
      add :best_week_pushups_on, :string
      add :best_session_pushups, :integer, null: false, default: 0
      add :best_session_pushups_on, :string
      add :best_pace_sec_per_burpee, :float
      add :best_pace_on, :string
      add :lifetime_pushup_milestone, :integer, null: false, default: 0
    end
  end
end
