defmodule BurpeeTrainer.Repo.Migrations.CreateCoachWorkoutDrafts do
  use Ecto.Migration

  def change do
    create table(:coach_workout_drafts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :parent_coach_recommendation_id,
          references(:coach_recommendations, on_delete: :nilify_all)

      add :workout_plan_id, references(:workout_plans), null: false
      add :source_json, :map, null: false
      add :brief, :text, null: false
      add :coach_comment, :text, null: false
      add :context_hash, :string, null: false
      add :profile_version, :integer, null: false
      add :model, :string, null: false
      add :prompt_version, :integer, null: false
      add :origin, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:coach_workout_drafts, [:user_id, :inserted_at])
    create index(:coach_workout_drafts, [:parent_coach_recommendation_id])
    create unique_index(:coach_workout_drafts, [:workout_plan_id])
  end
end
