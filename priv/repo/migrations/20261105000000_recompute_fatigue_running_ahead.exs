defmodule BurpeeTrainer.Repo.Migrations.RecomputeFatigueRunningAhead do
  @moduledoc """
  `Workouts.Fatigue` measured a rep ahead of its beat as negative lag, so going out ahead
  of the beat and settling onto it later read as falling behind: `kept_up` false and a
  `slip_at_sec`, and the planner eased off. A rep ahead of its beat now lags by nothing.
  Pace consistency mixed sets, so a set run evenly ahead of the beat read as uneven; it
  is now each set's evenness, averaged. Completed camera sessions get their fatigue and
  pace consistency recomputed from their locked `cadence_ms`
  and `program_snapshot`.
  """
  use Ecto.Migration

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.Fatigue

  def up do
    %{rows: rows} =
      repo().query!("""
      SELECT id, cadence_ms, program_snapshot FROM workout_sessions
      WHERE state = 'completed' AND cadence_ms IS NOT NULL AND program_snapshot IS NOT NULL
      """)

    for [id, cadence, snapshot] <- rows,
        {:ok, program} <- [Jason.decode(snapshot)] do
      # The columns as completion writes them, so the two never drift apart.
      columns = cadence |> Fatigue.for_session(program) |> Workouts.fatigue_fields()
      names = Map.keys(columns)

      assignments =
        names |> Enum.with_index(1) |> Enum.map_join(", ", fn {name, i} -> "#{name} = ?#{i}" end)

      repo().query!(
        "UPDATE workout_sessions SET #{assignments} WHERE id = ?#{length(names) + 1}",
        Enum.map(names, &sqlite_value(columns[&1])) ++ [id]
      )
    end
  end

  # The earlier values came from a calculation that no longer exists.
  def down, do: :ok

  # Raw queries bind booleans as text; Ecto reads SQLite booleans as 0 and 1.
  defp sqlite_value(true), do: 1
  defp sqlite_value(false), do: 0
  defp sqlite_value(value), do: value
end
