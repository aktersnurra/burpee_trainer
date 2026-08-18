defmodule BurpeeTrainer.Repo.Migrations.AddCoachMemory do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :timezone, :string, null: false, default: "Etc/UTC"
    end

    create table(:coach_profiles) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :memory_json, :map, null: false
      add :summary, :text, null: false
      add :refreshed_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:coach_profiles, [:user_id])

    create table(:coach_recommendations) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :workout_plan_id, references(:workout_plans, on_delete: :nilify_all)
      add :event_key, :string, null: false
      add :coach_comment, :text, null: false
      add :source_json, :map, null: false
      add :context_hash, :string, null: false
      add :profile_version, :integer, null: false
      add :model, :string, null: false
      add :prompt_version, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:coach_recommendations, [:user_id, :event_key])
    create index(:coach_recommendations, [:user_id, :inserted_at])

    create table(:coach_workout_threads) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :coach_recommendation_id, references(:coach_recommendations, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:coach_workout_threads, [:coach_recommendation_id])
    create index(:coach_workout_threads, [:user_id])

    create table(:coach_messages) do
      add :coach_workout_thread_id, references(:coach_workout_threads, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :role, :string, null: false
      add :kind, :string, null: false
      add :body, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:coach_messages, [:coach_workout_thread_id, :position])
  end
end
