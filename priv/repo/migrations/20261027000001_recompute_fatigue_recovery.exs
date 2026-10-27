defmodule BurpeeTrainer.Repo.Migrations.RecomputeFatigueRecovery do
  @moduledoc """
  `Workouts.Fatigue`'s recovery was the gap from a set's last rep to the next set's first,
  so finishing a set early read as slow recovery. It is now how late the first rep after a
  rest lands on its beat, net of the workout's first rep. Completed camera sessions get
  their fatigue recomputed from their locked `cadence_ms` and `program_snapshot`.
  """
  use Ecto.Migration

  alias BurpeeTrainer.Workouts.Fatigue

  def up do
    %{rows: rows} =
      repo().query!("""
      SELECT id, cadence_ms, program_snapshot FROM workout_sessions
      WHERE state = 'completed' AND cadence_ms IS NOT NULL AND program_snapshot IS NOT NULL
      """)

    for [id, cadence, snapshot] <- rows,
        {:ok, program} <- [Jason.decode(snapshot)] do
      fatigue = Fatigue.for_session(cadence, program)

      repo().query!(
        """
        UPDATE workout_sessions
        SET recovery_delta_sec = ?1, pace_delta_sec = ?2, fatigue_coverage = ?3,
            fatigue_decline = ?4, slip_at_sec = ?5, kept_up = ?6
        WHERE id = ?7
        """,
        [
          fatigue.recovery_delta_sec,
          fatigue.pace_delta_sec,
          fatigue.coverage,
          fatigue.decline,
          fatigue.slip_at_sec,
          sqlite_boolean(fatigue.kept_up),
          id
        ]
      )
    end
  end

  # The earlier values came from a calculation that no longer exists.
  def down, do: :ok

  # Raw queries bind booleans as text; Ecto reads SQLite booleans as 0 and 1.
  defp sqlite_boolean(nil), do: nil
  defp sqlite_boolean(value), do: if(value, do: 1, else: 0)
end
