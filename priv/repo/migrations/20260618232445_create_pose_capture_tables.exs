defmodule BurpeeTrainer.Repo.Migrations.CreatePoseCaptureTables do
  use Ecto.Migration

  def change do
    create table(:pose_capture_runs) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :plan_id, references(:workout_plans, on_delete: :nilify_all)
      add :workout_session_id, references(:workout_sessions, on_delete: :nilify_all)
      add :status, :string, null: false, default: "active"
      add :capture_version, :integer, null: false, default: 1
      add :started_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      add :aborted_at, :utc_datetime
      add :abort_reason, :string

      timestamps(type: :utc_datetime)
    end

    create index(:pose_capture_runs, [:user_id])
    create index(:pose_capture_runs, [:plan_id])
    create index(:pose_capture_runs, [:workout_session_id])
    create index(:pose_capture_runs, [:status])

    create table(:pose_trace_chunks) do
      add :pose_capture_run_id, references(:pose_capture_runs, on_delete: :delete_all),
        null: false

      add :segment, :string, null: false
      add :chunk_index, :integer, null: false
      add :started_at_ms, :integer, null: false
      add :ended_at_ms, :integer, null: false
      add :sample_count, :integer, null: false
      add :payload_json, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:pose_trace_chunks, [:pose_capture_run_id])
    create unique_index(:pose_trace_chunks, [:pose_capture_run_id, :chunk_index])
    create index(:pose_trace_chunks, [:pose_capture_run_id, :segment])
  end
end
