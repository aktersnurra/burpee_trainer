defmodule BurpeeTrainer.Repo.Migrations.AddCoachWorkoutDraftLifecycle do
  use Ecto.Migration

  def change do
    alter table(:coach_workout_drafts) do
      add :lifecycle_status, :string, null: false, default: "active"
    end

    execute(
      """
      UPDATE coach_workout_drafts AS draft
      SET lifecycle_status = 'superseded'
      WHERE EXISTS (
        SELECT 1
        FROM coach_workout_drafts AS newer
        WHERE newer.user_id = draft.user_id
          AND (
            newer.inserted_at > draft.inserted_at OR
            (newer.inserted_at = draft.inserted_at AND newer.id > draft.id)
          )
      )
      """,
      "UPDATE coach_workout_drafts SET lifecycle_status = 'active'"
    )

    create index(:coach_workout_drafts, [:user_id, :lifecycle_status, :inserted_at])

    create unique_index(:coach_workout_drafts, [:user_id],
             where: "lifecycle_status = 'active'",
             name: :coach_workout_drafts_one_active_per_user_index
           )
  end
end
