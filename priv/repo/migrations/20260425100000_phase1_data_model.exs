defmodule BurpeeTrainer.Repo.Migrations.Phase1DataModel do
  use Ecto.Migration

  def change do
    alter table(:workout_sessions) do
      add :mood, :integer
      add :tags, :text
      add :style_name, :string
      add :rate_per_min_actual, :float
      add :days_since_last, :integer
      add :rate_delta, :float
      add :rate_avg_rolling_3, :float
      add :time_of_day_bucket, :string
    end

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
  end
end
