defmodule BurpeeTrainer.Workouts.PoseCorpus do
  @moduledoc """
  Recorded camera sessions, exported for replaying the rep counter offline
  (`assets/js/tools/pose_corpus_report.mjs`, `fit_burpee_hsmm.mjs`). Owner-run and
  read-only; not user-scoped: it reads every completed capture in the database it is given.

  One file per session holds the main segment's samples in chunk order, the reps the
  camera emitted (`camera_reps_ms`, trace version 2 only), the logged and planned reps, the
  program snapshot and the session's camera cadence.
  """

  import Ecto.Query

  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts.{PoseCaptureRun, PoseTraceChunk}

  @spec export(Path.t()) :: [Path.t()]
  def export(dir) do
    File.mkdir_p!(dir)

    from(run in PoseCaptureRun,
      join: session in assoc(run, :workout_session),
      where: run.status == :completed and session.state == :completed,
      order_by: [asc: session.completed_at, asc: session.id],
      preload: [workout_session: session]
    )
    |> Repo.all()
    |> Enum.map(&session_trace/1)
    |> Enum.reject(&(&1.samples == []))
    |> Enum.map(&write(dir, &1))
  end

  @spec session_trace(PoseCaptureRun.t()) :: map()
  def session_trace(%PoseCaptureRun{workout_session: session} = run) do
    payloads =
      from(chunk in PoseTraceChunk,
        where: chunk.pose_capture_run_id == ^run.id and chunk.segment == :main,
        order_by: chunk.chunk_index,
        select: chunk.payload_json
      )
      |> Repo.all()
      |> Enum.map(&Jason.decode!/1)

    %{
      session_id: session.id,
      completed_at: session.completed_at,
      burpee_type: session.burpee_type,
      capture_mode: session.capture_mode,
      reps: session.burpee_count_actual,
      reps_planned: session.burpee_count_planned,
      program: session.program_snapshot,
      cadence_ms: decode_cadence(session.cadence_ms),
      version: payloads |> Enum.map(& &1["version"]) |> Enum.max(fn -> 1 end),
      samples: Enum.flat_map(payloads, & &1["samples"]),
      camera_reps_ms: Enum.flat_map(payloads, &Map.get(&1, "reps", []))
    }
  end

  defp write(dir, trace) do
    path = Path.join(dir, "session-#{trace.session_id}.json.gz")
    File.write!(path, :zlib.gzip(Jason.encode!(trace)))
    path
  end

  defp decode_cadence(nil), do: nil
  defp decode_cadence(cadence), do: Jason.decode!(cadence)
end
