defmodule BurpeeTrainer.E2E.Verify do
  @moduledoc false

  import Ecto.Query

  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts.{PoseCaptureRun, PoseTraceChunk, WorkoutSession}

  @spec run(pos_integer(), Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def run(user_id, client_session_id)
      when is_integer(user_id) and user_id > 0 and is_binary(client_session_id) do
    if Ecto.UUID.cast(client_session_id) == {:ok, client_session_id} do
      sessions =
        Repo.all(
          from(session in WorkoutSession,
            where:
              session.user_id == ^user_id and
                session.client_session_id == ^client_session_id
          )
        )

      case sessions do
        [session] ->
          evidence =
            %{
              count: 1,
              state: session.state,
              source_kind: session.source_kind,
              session_id: session.id,
              user_id: session.user_id,
              plan_id: session.plan_id,
              workout_video_id: session.workout_video_id,
              client_session_id: session.client_session_id,
              content_hash: session.content_hash,
              display_name_snapshot: session.display_name_snapshot,
              workout_type_snapshot: session.workout_type_snapshot,
              program_snapshot: session.program_snapshot,
              video_snapshot: session.video_snapshot,
              burpee_count_planned: session.burpee_count_planned,
              duration_sec_planned: session.duration_sec_planned,
              burpee_count_actual: session.burpee_count_actual,
              duration_sec_actual: session.duration_sec_actual,
              note_pre: session.note_pre,
              note_post: session.note_post,
              mood: session.mood,
              context_low_energy: session.context_low_energy,
              context_high_energy: session.context_high_energy,
              context_heat_affected: session.context_heat_affected,
              primary_limiter: session.primary_limiter,
              preference_feedback: session.preference_feedback,
              completed_at: session.completed_at,
              capture_mode: session.capture_mode,
              cadence_ms: session.cadence_ms,
              target_pace_sec: session.target_pace_sec,
              pace_consistency: session.pace_consistency,
              tags: session.tags
            }
            |> Map.merge(pose_evidence(session))

          {:ok, evidence}

        sessions ->
          {:error, {:unexpected_session_count, length(sessions)}}
      end
    else
      {:error, :invalid_client_session_id}
    end
  end

  def run(_user_id, _client_session_id), do: {:error, :invalid_arguments}

  defp pose_evidence(session) do
    case Repo.get_by(PoseCaptureRun,
           user_id: session.user_id,
           workout_session_id: session.id
         ) do
      %PoseCaptureRun{} = run ->
        chunks =
          Repo.all(
            from(chunk in PoseTraceChunk,
              where: chunk.pose_capture_run_id == ^run.id,
              order_by: [asc: chunk.chunk_index]
            )
          )

        %{
          pose_capture_run_id: run.id,
          pose_capture_run_user_id: run.user_id,
          pose_capture_run_workout_session_id: run.workout_session_id,
          pose_capture_run_status: run.status,
          pose_capture_chunk_count: length(chunks),
          pose_capture_chunk_indexes: Enum.map(chunks, & &1.chunk_index),
          pose_capture_chunk_digests: Enum.map(chunks, & &1.payload_digest)
        }

      nil ->
        %{
          pose_capture_run_id: nil,
          pose_capture_run_user_id: nil,
          pose_capture_run_workout_session_id: nil,
          pose_capture_run_status: nil,
          pose_capture_chunk_count: 0,
          pose_capture_chunk_indexes: [],
          pose_capture_chunk_digests: []
        }
    end
  end

  @spec main() :: no_return()
  def main do
    if Mix.env() == :prod do
      raise "workout-session E2E verification refuses to run in production"
    end

    require_disposable_database!()

    arguments =
      case System.argv() do
        ["--" | rest] -> rest
        arguments -> arguments
      end

    case arguments do
      [user_id_text, client_session_id] ->
        with {user_id, ""} <- Integer.parse(user_id_text),
             {:ok, evidence} <- run(user_id, client_session_id) do
          IO.puts("E2E_VERIFY=" <> Jason.encode!(evidence))
        else
          {:error, {:unexpected_session_count, count}} ->
            IO.puts(
              :stderr,
              "Expected exactly one session for the E2E user and client_session_id; found #{count}"
            )

            System.halt(1)

          _invalid_arguments ->
            IO.puts(:stderr, "user_id must be an integer and client_session_id must be a UUID")
            System.halt(2)
        end

      _arguments ->
        IO.puts(
          :stderr,
          "usage: mix run scripts/e2e/verify.exs -- USER_ID CLIENT_SESSION_ID"
        )

        System.halt(2)
    end
  end

  defp require_disposable_database! do
    fixture = Application.get_env(:burpee_trainer, :adaptive_e2e_fixture, [])
    database = Keyword.get(fixture, :database_path)

    valid? =
      Keyword.get(fixture, :enabled, false) and is_binary(database) and
        Path.dirname(database) == "/tmp" and
        String.starts_with?(Path.basename(database), "adaptive-home-coach-e2e-") and
        String.ends_with?(database, ".db") and Repo.config()[:database] == database

    unless valid?, do: raise("E2E verification requires the disposable adaptive E2E database")
  end
end

if System.get_env("E2E_VERIFY_LIBRARY_ONLY") != "1" do
  BurpeeTrainer.E2E.Verify.main()
end
