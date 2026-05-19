defmodule BurpeeTrainer.Repo.Migrations.FixUserStatsColumns do
  use Ecto.Migration

  # The original migration used timestamps(updated_at: true, inserted_at: false)
  # which created a column literally named "true" instead of "updated_at".
  # Drop and recreate with the correct schema. Data loss is acceptable — the
  # table only stores a previous_best_weeks counter that is recomputed from sessions.
  def up do
    drop table(:user_stats)

    create table(:user_stats, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), primary_key: true
      add :previous_best_weeks, :integer, null: false, default: 0
      add :previous_best_ended_on, :string

      timestamps(inserted_at: false)
    end
  end

  def down do
    drop table(:user_stats)
  end
end
