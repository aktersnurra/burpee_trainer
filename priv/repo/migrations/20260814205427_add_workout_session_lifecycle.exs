defmodule BurpeeTrainer.Repo.Migrations.AddWorkoutSessionLifecycle do
  use Ecto.Migration

  def change do
    alter table(:workout_sessions) do
      add :status, :string, null: false, default: "reported"
      add :source, :string, null: false, default: "manual"
      add :video_id, references(:workout_videos, on_delete: :nilify_all)
      add :report_fingerprint, :string
      add :report_pending_at, :utc_datetime
      add :reported_at, :utc_datetime
      add :aborted_at, :utc_datetime
    end

    execute("UPDATE workout_sessions SET source = 'plan' WHERE plan_id IS NOT NULL")
    execute("UPDATE workout_sessions SET reported_at = inserted_at WHERE status = 'reported'")

    create index(:workout_sessions, [:video_id])

    create unique_index(:workout_sessions, [:user_id],
             where: "status IN ('running', 'report_pending')",
             name: :workout_sessions_one_unresolved_per_user_index
           )
  end
end
