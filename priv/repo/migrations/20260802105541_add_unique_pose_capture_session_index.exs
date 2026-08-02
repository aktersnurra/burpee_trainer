defmodule BurpeeTrainer.Repo.Migrations.AddUniquePoseCaptureSessionIndex do
  use Ecto.Migration

  def change do
    create unique_index(:pose_capture_runs, [:workout_session_id],
             where: "workout_session_id IS NOT NULL",
             name: :pose_capture_runs_workout_session_id_unique_index
           )
  end
end
