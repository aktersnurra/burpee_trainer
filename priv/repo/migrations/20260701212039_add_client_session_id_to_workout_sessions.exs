defmodule BurpeeTrainer.Repo.Migrations.AddClientSessionIdToWorkoutSessions do
  use Ecto.Migration

  def change do
    alter table(:workout_sessions) do
      add :client_session_id, :string
    end

    execute(
      """
      UPDATE workout_sessions
      SET client_session_id =
        lower(hex(randomblob(4))) || '-' ||
        lower(hex(randomblob(2))) || '-4' ||
        substr(lower(hex(randomblob(2))), 2) || '-' ||
        substr('89ab', abs(random()) % 4 + 1, 1) ||
        substr(lower(hex(randomblob(2))), 2) || '-' ||
        lower(hex(randomblob(6)))
      WHERE client_session_id IS NULL
      """,
      """
      UPDATE workout_sessions
      SET client_session_id = NULL
      """
    )

    create unique_index(:workout_sessions, [:user_id, :client_session_id])
  end
end
