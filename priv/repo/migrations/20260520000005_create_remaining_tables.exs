defmodule BurpeeTrainer.Repo.Migrations.CreateRemainingTables do
  use Ecto.Migration

  def change do
    create table(:style_performances) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :style_name, :string, null: false
      add :burpee_type, :string, null: false
      add :mood, :integer, null: false
      add :level, :string, null: false
      add :time_of_day_bucket, :string, null: false
      add :session_count, :integer, null: false, default: 0
      add :completion_ratio_sum, :float, null: false, default: 0.0
      add :rate_sum, :float, null: false, default: 0.0

      timestamps(type: :utc_datetime)
    end

    create index(:style_performances, [:user_id])

    create unique_index(
             :style_performances,
             [:user_id, :style_name, :burpee_type, :mood, :level, :time_of_day_bucket]
           )

    create table(:workout_videos) do
      add :name, :string, null: false
      add :filename, :string, null: false
      add :burpee_type, :string, null: false
      add :duration_sec, :integer, null: false
      add :burpee_count, :integer

      timestamps(updated_at: false)
    end

    create unique_index(:workout_videos, [:filename])

    create table(:user_stats, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), primary_key: true
      add :previous_best_weeks, :integer, null: false, default: 0
      add :previous_best_ended_on, :string

      timestamps(inserted_at: false)
    end
  end
end
