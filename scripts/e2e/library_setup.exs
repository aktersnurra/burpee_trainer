defmodule BurpeeTrainer.E2E.LibrarySetup do
  @moduledoc false

  import Ecto.Query

  alias BurpeeTrainer.{Accounts, Repo, Videos, Workouts}
  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Coach.{Client, Policy}
  alias BurpeeTrainer.PlanCompiler.ProgramHash

  alias BurpeeTrainer.Workouts.{
    CoachRecommendation,
    Error,
    PoseCaptureRun,
    PoseTraceChunk,
    WorkoutPlan,
    WorkoutSession,
    WorkoutVideo
  }

  @modes ~w[
    published-plan
    pending-candidate
    available-video
    started-plan-session
    completed-history
    provider-failure
  ]
  @mode_usage "published-plan|pending-candidate|available-video|started-plan-session|completed-history|provider-failure"

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(mode, options \\ [])

  def run(mode, options) when mode in @modes do
    require_disposable_database!()
    run_id = Keyword.get_lazy(options, :run_id, &default_run_id/0) |> safe_run_id()
    username = fixture_username(run_id, mode)
    password = Keyword.get_lazy(options, :password, fn -> fixture_password(run_id, mode) end)

    base_url =
      Keyword.get(options, :base_url, System.get_env("E2E_BASE_URL") || "http://127.0.0.1:4000")

    case ensure_fixture_user(username, password) do
      {:ok, user, created_user?} ->
        try do
          maybe_induce_failure!(options, :after_registration)

          case create_mode_fixture(user, mode, run_id) do
            {:ok, evidence} ->
              maybe_induce_failure!(options, :after_fixture_creation)

              {:ok,
               evidence
               |> Map.merge(%{
                 mode: mode,
                 user_id: user.id,
                 username: username,
                 password: password,
                 base_url: base_url,
                 login_url: "#{base_url}/login"
               })}

            {:error, reason} ->
              maybe_cleanup_fixture!(created_user?, user)
              {:error, reason}
          end
        rescue
          error ->
            maybe_cleanup_fixture!(created_user?, user)
            {:error, {:fixture_setup_failed, Exception.message(error)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run(mode, _options), do: {:error, {:unsupported_fixture_mode, mode}}

  @spec main() :: :ok
  def main do
    arguments =
      case System.argv() do
        ["--" | rest] -> rest
        arguments -> arguments
      end

    mode =
      case arguments do
        [mode] when mode in @modes -> mode
        [mode] -> raise "unsupported fixture mode #{inspect(mode)}; expected #{@mode_usage}"
        _arguments -> raise "usage: mix run scripts/e2e/library_setup.exs -- #{@mode_usage}"
      end

    options =
      case System.get_env("E2E_INDUCED_FAILURE_AFTER") do
        nil -> []
        value -> [induced_failure_after: value]
      end

    case run(mode, options) do
      {:ok, report} ->
        IO.puts("E2E_LIBRARY_SETUP=" <> Jason.encode!(report))
        :ok

      {:error, reason} ->
        raise "E2E library setup failed: #{inspect(reason)}"
    end
  end

  defp create_mode_fixture(user, "published-plan", run_id) do
    with {:ok, plan} <- published_plan(user, "Published library #{run_id}") do
      persisted = Repo.get_by!(WorkoutPlan, id: plan.id, user_id: user.id)

      {:ok,
       %{
         plan_id: persisted.id,
         plan_user_id: persisted.user_id,
         plan_state: persisted.state,
         plan_origin: persisted.origin,
         plan_name: persisted.name,
         definition_json: persisted.definition_json,
         program_json: persisted.program_json,
         content_hash: persisted.content_hash,
         library_url: "/workouts"
       }}
    end
  end

  defp create_mode_fixture(user, "pending-candidate", run_id) do
    slot_date = next_monday(Date.utc_today())

    with {:ok, slot} <- Policy.required_slot_for_date(user, slot_date),
         {:ok, recommendation} <-
           Workouts.ensure_recommendation(user, %{
             slot_key: "e2e-pending-#{run_id}",
             slot_date: slot_date,
             rationale: "Deterministic pending candidate fixture"
           }),
         {:ok, attached} <-
           ensure_pending_candidate(user, recommendation, run_id, slot.duration_sec) do
      persisted = Repo.get_by!(CoachRecommendation, id: attached.id, user_id: user.id)
      draft = Repo.get_by!(WorkoutPlan, id: persisted.pending_draft_id, user_id: user.id)

      {:ok,
       %{
         recommendation_id: persisted.id,
         selected_workout_plan_id: persisted.selected_workout_plan_id,
         pending_draft_id: draft.id,
         pending_draft_state: draft.state,
         pending_draft_user_id: draft.user_id,
         pending_draft_definition_json: draft.definition_json,
         pending_draft_program_json: draft.program_json,
         pending_draft_content_hash: draft.content_hash,
         slot_key: persisted.slot_key,
         slot_date: persisted.slot_date,
         home_url: "/"
       }}
    end
  end

  defp create_mode_fixture(user, "available-video", run_id) do
    with {:ok, video} <- ensure_available_video(user, run_id),
         {:ok, snapshot, content_hash} <- ProgramHash.video_snapshot(video_snapshot_attrs(video)) do
      persisted = Repo.get!(WorkoutVideo, video.id)

      {:ok,
       %{
         video_id: persisted.id,
         video_name: persisted.name,
         video_filename: persisted.filename,
         video_available: persisted.available,
         video_snapshot: snapshot,
         content_hash: content_hash,
         videos_url: "/videos"
       }}
    end
  end

  defp create_mode_fixture(user, "started-plan-session", run_id) do
    client_session_id = fixture_client_session_id(run_id, "started-plan-session")

    with {:ok, plan} <- published_plan(user, "Started session #{run_id}"),
         {:ok, session} <- Workouts.start_plan(user, plan.id, client_session_id) do
      persisted = Repo.get_by!(WorkoutSession, id: session.id, user_id: user.id)

      {:ok,
       %{
         plan_id: plan.id,
         plan_content_hash: plan.content_hash,
         plan_definition_json: plan.definition_json,
         plan_program_json: plan.program_json,
         session_id: persisted.id,
         session_user_id: persisted.user_id,
         session_state: persisted.state,
         source_kind: persisted.source_kind,
         client_session_id: persisted.client_session_id,
         content_hash: persisted.content_hash,
         display_name_snapshot: persisted.display_name_snapshot,
         workout_type_snapshot: persisted.workout_type_snapshot,
         program_snapshot: persisted.program_snapshot,
         video_snapshot: persisted.video_snapshot,
         session_url: "/session/#{persisted.id}"
       }}
    end
  end

  defp create_mode_fixture(user, "completed-history", run_id) do
    client_session_id = fixture_client_session_id(run_id, "completed-history")

    with {:ok, plan} <- published_plan(user, "Completed history #{run_id}"),
         {:ok, started} <- Workouts.start_plan(user, plan.id, client_session_id),
         {:ok, completed} <- complete_history_session(user, started) do
      persisted = Repo.get_by!(WorkoutSession, id: completed.id, user_id: user.id)

      evidence =
        %{
          plan_id: plan.id,
          plan_content_hash: plan.content_hash,
          plan_definition_json: plan.definition_json,
          plan_program_json: plan.program_json,
          session_id: persisted.id,
          session_user_id: persisted.user_id,
          session_state: persisted.state,
          source_kind: persisted.source_kind,
          client_session_id: persisted.client_session_id,
          content_hash: persisted.content_hash,
          display_name_snapshot: persisted.display_name_snapshot,
          workout_type_snapshot: persisted.workout_type_snapshot,
          program_snapshot: persisted.program_snapshot,
          video_snapshot: persisted.video_snapshot,
          burpee_count_planned: persisted.burpee_count_planned,
          duration_sec_planned: persisted.duration_sec_planned,
          burpee_count_actual: persisted.burpee_count_actual,
          duration_sec_actual: persisted.duration_sec_actual,
          note_pre: persisted.note_pre,
          note_post: persisted.note_post,
          mood: persisted.mood,
          context_low_energy: persisted.context_low_energy,
          context_high_energy: persisted.context_high_energy,
          context_heat_affected: persisted.context_heat_affected,
          primary_limiter: persisted.primary_limiter,
          preference_feedback: persisted.preference_feedback,
          capture_mode: persisted.capture_mode,
          cadence_ms: persisted.cadence_ms,
          target_pace_sec: persisted.target_pace_sec,
          pace_consistency: persisted.pace_consistency,
          completed_at: persisted.completed_at,
          history_url: "/stats"
        }
        |> Map.merge(pose_evidence(persisted))

      {:ok, evidence}
    end
  end

  defp create_mode_fixture(user, "provider-failure", run_id) do
    with {:ok, recommendation} <-
           Workouts.ensure_recommendation(user, %{
             slot_key: "e2e-provider-failure-#{run_id}",
             slot_date: next_monday(Date.utc_today()),
             rationale: "Provider disabled; deterministic fallback remains"
           }) do
      persisted = Repo.get_by!(CoachRecommendation, id: recommendation.id, user_id: user.id)

      provider_enabled =
        :burpee_trainer |> Application.get_env(:llm_provider, []) |> Keyword.get(:enabled, false)

      if provider_enabled do
        {:error, :provider_must_be_disabled}
      else
        caller = self()

        req =
          Req.new(
            plug: fn conn ->
              send(caller, :provider_http_requested)
              Plug.Conn.send_resp(conn, 500, "request must not be reached")
            end
          )

        provider_result =
          Client.complete([], req: req, config: [enabled: false, url: nil, api_key: nil])

        request_count =
          receive do
            :provider_http_requested -> 1
          after
            0 -> 0
          end

        case provider_result do
          {:error, %Error{code: :provider_unavailable}} when request_count == 0 ->
            selected = Repo.get!(WorkoutPlan, persisted.selected_workout_plan_id)

            {:ok,
             %{
               recommendation_id: persisted.id,
               recommendation_user_id: persisted.user_id,
               selected_workout_plan_id: persisted.selected_workout_plan_id,
               selected_plan_state: selected.state,
               selected_plan_content_hash: selected.content_hash,
               provider_enabled: false,
               provider_result: "provider_unavailable",
               provider_request_count: request_count,
               fallback_available: true,
               home_url: "/"
             }}

          _unexpected ->
            {:error, {:provider_zero_request_contract_failed, provider_result, request_count}}
        end
      end
    end
  end

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

  defp published_plan(user, name) do
    case Repo.get_by(WorkoutPlan, user_id: user.id, name: name, state: :published) do
      %WorkoutPlan{} = plan ->
        {:ok, plan}

      nil ->
        with {:ok, draft} <-
               Workouts.create_user_draft(user, %{
                 "definition" => definition(name, 120),
                 "request_text" => "Create deterministic E2E library content"
               }),
             {:ok, plan} <- Workouts.publish_draft(user, draft.id) do
          {:ok, plan}
        end
    end
  end

  defp ensure_fixture_user(username, password) do
    case Accounts.get_user_by_username(username) do
      %User{} = user ->
        {:ok, user, false}

      nil ->
        case Accounts.register_user(%{"username" => username, "password" => password}) do
          {:ok, user} -> {:ok, user, true}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp ensure_pending_candidate(user, recommendation, run_id, duration_sec) do
    case recommendation do
      %CoachRecommendation{pending_draft_id: draft_id} when is_integer(draft_id) ->
        case Repo.get_by(WorkoutPlan, id: draft_id, user_id: user.id, state: :draft) do
          %WorkoutPlan{} -> {:ok, recommendation}
          nil -> attach_pending_candidate(user, recommendation, run_id, duration_sec)
        end

      %CoachRecommendation{} ->
        attach_pending_candidate(user, recommendation, run_id, duration_sec)
    end
  end

  defp attach_pending_candidate(user, recommendation, run_id, duration_sec) do
    Workouts.attach_candidate(user, recommendation.id, %{
      definition: definition("Pending candidate #{run_id}", duration_sec),
      request_text: "Create the deterministic pending candidate",
      rationale: "Candidate awaits explicit acceptance"
    })
  end

  defp ensure_available_video(user, run_id) do
    filename = fixture_video_filename(user.username)

    case Repo.get_by(WorkoutVideo, filename: filename) do
      %WorkoutVideo{} = video ->
        {:ok, video}

      nil ->
        Videos.create_video(%{
          name: "Available E2E video #{run_id}",
          filename: filename,
          burpee_type: :six_count,
          duration_sec: 180,
          burpee_count: nil,
          available: true,
          format: :follow_along
        })
    end
  end

  defp complete_history_session(_user, %WorkoutSession{state: :completed} = session),
    do: {:ok, session}

  defp complete_history_session(user, %WorkoutSession{state: :started} = session) do
    Workouts.complete_session(
      user,
      session.id,
      %{
        "burpee_count_actual" => 10,
        "duration_sec_actual" => 120,
        "note_post" => "Deterministic completed history fixture",
        "preference_feedback" => "choose_again"
      },
      :timed
    )
  end

  defp maybe_induce_failure!(options, stage) do
    requested = Keyword.get(options, :induced_failure_after)

    if requested in [
         stage,
         Atom.to_string(stage),
         String.replace(Atom.to_string(stage), "_", "-")
       ] do
      raise "induced fixture failure after #{stage}"
    end
  end

  defp maybe_cleanup_fixture!(true, %User{} = user), do: cleanup_fixture!(user)
  defp maybe_cleanup_fixture!(false, %User{}), do: :ok

  defp cleanup_fixture!(%User{} = user) do
    filename = fixture_video_filename(user.username)

    case Repo.immediate_transaction(fn ->
           Repo.delete_all(from(video in WorkoutVideo, where: video.filename == ^filename))
           delete_fixture_user!(user)
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> raise "fixture cleanup failed: #{inspect(reason)}"
    end
  end

  defp delete_fixture_user!(user) do
    trigger_name = "workout_plans_draft_only_delete_trigger"

    [[trigger_sql]] =
      Repo.query!(
        "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?",
        [trigger_name]
      ).rows

    Repo.query!("DROP TRIGGER #{trigger_name}")
    result = Repo.delete(user)
    Repo.query!(trigger_sql)

    case result do
      {:ok, _deleted} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp fixture_client_session_id(run_id, mode) do
    hex =
      :crypto.hash(:sha256, "#{run_id}:#{mode}")
      |> binary_part(0, 16)
      |> Base.encode16(case: :lower)

    Enum.join(
      [
        String.slice(hex, 0, 8),
        String.slice(hex, 8, 4),
        String.slice(hex, 12, 4),
        String.slice(hex, 16, 4),
        String.slice(hex, 20, 12)
      ],
      "-"
    )
  end

  defp fixture_password(run_id, mode) do
    suffix =
      :crypto.hash(:sha256, "#{run_id}:#{mode}:password")
      |> Base.url_encode64(padding: false)
      |> String.slice(0, 20)

    "Fixture!#{suffix}"
  end

  defp definition(name, duration_sec) when is_integer(duration_sec) and duration_sec > 0 do
    reps = max(div(duration_sec, 12), 1)
    cadence = duration_sec / reps

    %{
      "version" => 1,
      "name" => name,
      "burpee_type" => "six_count",
      "target_reps" => reps,
      "target_duration_sec" => duration_sec,
      "pacing_style" => "even",
      "rationale" => "Deterministic disposable E2E workout.",
      "events" => [
        %{
          "kind" => "work",
          "reps" => reps,
          "sec_per_rep" => cadence,
          "sec_per_burpee" => cadence
        }
      ]
    }
  end

  defp video_snapshot_attrs(video) do
    %{
      "name" => video.name,
      "filename" => video.filename,
      "type" => video.burpee_type,
      "duration" => video.duration_sec,
      "count" => video.burpee_count,
      "format" => video.format
    }
  end

  defp next_monday(date) do
    days = rem(8 - Date.day_of_week(date), 7)
    Date.add(date, days)
  end

  defp require_disposable_database! do
    fixture = Application.get_env(:burpee_trainer, :adaptive_e2e_fixture, [])
    database = Keyword.get(fixture, :database_path)
    configured_database = Repo.config()[:database]

    valid? =
      Keyword.get(fixture, :enabled, false) and is_binary(database) and
        Path.dirname(database) == "/tmp" and
        String.starts_with?(Path.basename(database), "adaptive-home-coach-e2e-") and
        String.ends_with?(database, ".db") and configured_database == database

    unless valid?, do: raise("E2E library setup requires the disposable adaptive E2E database")
  end

  defp default_run_id do
    System.get_env("E2E_RUN_ID") || Integer.to_string(System.system_time(:millisecond), 36)
  end

  defp safe_run_id(run_id) do
    run_id
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_.-]/, "-")
    |> String.slice(0, 24)
  end

  defp fixture_username(run_id, mode) do
    suffix =
      :crypto.hash(:sha256, "#{run_id}:#{mode}")
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    "e2e_workout_#{suffix}"
  end

  defp fixture_video_filename(username), do: "e2e-available-#{username}.mp4"
end

if System.get_env("E2E_LIBRARY_SETUP_ONLY") != "1" do
  BurpeeTrainer.E2E.LibrarySetup.main()
end
