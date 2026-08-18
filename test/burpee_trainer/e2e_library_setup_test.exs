defmodule BurpeeTrainer.E2ELibrarySetupTest do
  use ExUnit.Case, async: false

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.PlanCompiler.ProgramHash
  alias BurpeeTrainer.TestSupport.IsolatedMigrationRepo

  alias BurpeeTrainer.Workouts.{
    CoachRecommendation,
    PoseCaptureRun,
    PoseTraceChunk,
    WorkoutPlan,
    WorkoutSession,
    WorkoutVideo
  }

  @script "scripts/e2e/library_setup.exs"
  @modes ~w[
    published-plan
    pending-candidate
    available-video
    started-plan-session
    completed-history
    provider-failure
  ]

  setup do
    suffix = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = "/tmp/adaptive-home-coach-e2e-library-#{suffix}.db"
    paths = Enum.map(["", "-shm", "-wal"], &(database <> &1))
    clear_paths!(paths)
    on_exit(fn -> clear_paths!(paths) end)
    {:ok, database: database}
  end

  @tag timeout: :infinity
  test "all modes are exact rerun-idempotent and scripts verify and clean persisted facts",
       %{database: database} do
    env = fixture_env(database)
    assert_mix_ok!(["ecto.create", "--quiet"], env)
    assert_mix_ok!(["ecto.migrate", "--quiet"], env)

    reports =
      Map.new(@modes, fn mode ->
        first = run_mode!(mode, env)
        assert run_mode!(mode, env) == first
        {mode, first}
      end)

    setup = run_script_report!("scripts/e2e/setup.exs", [], env, "E2E_SETUP=")
    assert setup == reports["started-plan-session"]

    started = reports["started-plan-session"]

    verified =
      run_script_report!(
        "scripts/e2e/verify.exs",
        [Integer.to_string(started["user_id"]), started["client_session_id"]],
        env,
        "E2E_VERIFY="
      )

    assert verified["count"] == 1
    assert verified["session_id"] == started["session_id"]
    assert verified["content_hash"] == started["content_hash"]
    assert verified["program_snapshot"] == started["program_snapshot"]
    assert verified["pose_capture_run_id"] == nil
    assert verified["pose_capture_run_status"] == nil
    assert verified["pose_capture_chunk_count"] == 0
    assert verified["pose_capture_chunk_indexes"] == []
    assert verified["pose_capture_chunk_digests"] == []

    completed = reports["completed-history"]

    for field <-
          ~w[
            burpee_count_planned duration_sec_planned note_pre note_post mood
            context_low_energy context_high_energy context_heat_affected primary_limiter
            preference_feedback capture_mode cadence_ms target_pace_sec pace_consistency
            pose_capture_run_id pose_capture_run_user_id pose_capture_run_workout_session_id
            pose_capture_run_status pose_capture_chunk_count pose_capture_chunk_indexes
            pose_capture_chunk_digests
          ] do
      assert Map.has_key?(completed, field)
    end

    assert completed["burpee_count_planned"] == 10
    assert completed["duration_sec_planned"] == 120
    assert completed["note_pre"] == nil
    assert completed["note_post"] == "Deterministic completed history fixture"
    assert completed["mood"] == nil
    assert completed["context_low_energy"] == false
    assert completed["context_high_energy"] == false
    assert completed["context_heat_affected"] == false
    assert completed["primary_limiter"] == nil
    assert completed["preference_feedback"] == "choose_again"
    assert completed["capture_mode"] == "timed"
    assert completed["cadence_ms"] == nil
    assert completed["target_pace_sec"] == nil
    assert completed["pace_consistency"] == nil
    assert completed["pose_capture_run_id"] == nil
    assert completed["pose_capture_run_user_id"] == nil
    assert completed["pose_capture_run_workout_session_id"] == nil
    assert completed["pose_capture_run_status"] == nil
    assert completed["pose_capture_chunk_count"] == 0
    assert completed["pose_capture_chunk_indexes"] == []
    assert completed["pose_capture_chunk_digests"] == []

    completed_verified =
      run_script_report!(
        "scripts/e2e/verify.exs",
        [Integer.to_string(completed["user_id"]), completed["client_session_id"]],
        env,
        "E2E_VERIFY="
      )

    for field <-
          ~w[
            burpee_count_planned duration_sec_planned note_pre note_post mood
            context_low_energy context_high_energy context_heat_affected primary_limiter
            preference_feedback capture_mode cadence_ms target_pace_sec pace_consistency
            pose_capture_run_id pose_capture_run_user_id pose_capture_run_workout_session_id
            pose_capture_run_status pose_capture_chunk_count pose_capture_chunk_indexes
            pose_capture_chunk_digests
          ] do
      assert completed_verified[field] == completed[field]
    end

    _repo_pid = start_isolated_repo!(database)
    Enum.each(reports, fn {mode, report} -> assert_persisted_report!(mode, report) end)

    available = reports["available-video"]
    video_client_session_id = Ecto.UUID.generate()

    video_session =
      %WorkoutSession{
        user_id: available["user_id"],
        state: :started,
        source_kind: :video,
        workout_video_id: available["video_id"],
        display_name_snapshot: available["video_name"],
        workout_type_snapshot: :six_count,
        video_snapshot: available["video_snapshot"],
        content_hash: available["content_hash"],
        client_session_id: video_client_session_id,
        started_at: ~U[2026-08-31 00:00:00Z],
        burpee_type: :six_count,
        burpee_count_planned: available["video_snapshot"]["count"],
        duration_sec_planned: available["video_snapshot"]["duration"]
      }
      |> WorkoutSession.start_changeset()
      |> IsolatedMigrationRepo.insert!()

    stop_supervised(IsolatedMigrationRepo)

    video_verified =
      run_script_report!(
        "scripts/e2e/verify.exs",
        [Integer.to_string(available["user_id"]), video_client_session_id],
        env,
        "E2E_VERIFY="
      )

    assert video_verified["workout_video_id"] == available["video_id"]
    assert video_verified["plan_id"] == nil
    assert video_verified["video_snapshot"] == available["video_snapshot"]
    assert video_verified["content_hash"] == available["content_hash"]
    assert video_verified["session_id"] == video_session.id
    assert video_verified["client_session_id"] == video_client_session_id

    _repo_pid = start_isolated_repo!(database)
    IsolatedMigrationRepo.delete!(video_session)
    pose_run = insert_completed_pose_evidence!(completed)
    stop_supervised(IsolatedMigrationRepo)

    pose_verified =
      run_script_report!(
        "scripts/e2e/verify.exs",
        [Integer.to_string(completed["user_id"]), completed["client_session_id"]],
        env,
        "E2E_VERIFY="
      )

    assert pose_verified["pose_capture_run_id"] == pose_run.id
    assert pose_verified["pose_capture_run_user_id"] == completed["user_id"]
    assert pose_verified["pose_capture_run_workout_session_id"] == completed["session_id"]
    assert pose_verified["pose_capture_run_status"] == "completed"
    assert pose_verified["pose_capture_chunk_count"] == 2
    assert pose_verified["pose_capture_chunk_indexes"] == [0, 2]
    assert length(pose_verified["pose_capture_chunk_digests"]) == 2
    assert Enum.all?(pose_verified["pose_capture_chunk_digests"], &is_binary/1)

    _repo_pid = start_isolated_repo!(database)
    unrelated_filename = "unrelated-video-#{System.unique_integer([:positive])}.mp4"
    now = "2026-08-31T00:00:00Z"

    IsolatedMigrationRepo.query!(
      """
      INSERT INTO workout_videos
        (name, filename, burpee_type, duration_sec, available, format, inserted_at)
      VALUES ('Unrelated video', ?, 'six_count', 60, 1, 'follow_along', ?)
      """,
      [unrelated_filename, now]
    )

    stop_supervised(IsolatedMigrationRepo)

    deleted = run_cleanup!(available["user_id"], env)
    assert deleted["status"] == "deleted"
    assert deleted["deleted"]["videos"] == 1
    assert run_cleanup!(available["user_id"], env)["status"] == "already_absent"

    assert run_cleanup!(started["user_id"], env)["status"] == "deleted"
    assert run_cleanup!(started["user_id"], env)["status"] == "already_absent"

    _repo_pid = start_isolated_repo!(database)
    refute IsolatedMigrationRepo.get(User, available["user_id"])
    refute IsolatedMigrationRepo.get(WorkoutVideo, available["video_id"])
    refute IsolatedMigrationRepo.get(User, started["user_id"])
    assert IsolatedMigrationRepo.get_by!(WorkoutVideo, filename: unrelated_filename)
    stop_supervised(IsolatedMigrationRepo)
  end

  test "fixture entrypoint refuses an ordinary test database before creating a user" do
    {output, status} =
      System.cmd("mix", ["run", @script, "--", "published-plan"],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "requires the disposable adaptive E2E database"
  end

  test "runtime refuses an outside tmp database before touching its bytes or starting the app" do
    outside = "/var/tmp/adaptive-home-coach-e2e-outside-#{System.unique_integer([:positive])}.db"
    marker = "outside-must-remain"
    original_bytes = create_sentinel_database!(outside, marker)
    on_exit(fn -> clear_database_paths!(outside) end)

    {output, status} = run_fixture_process("published-plan", outside)

    assert status == 4
    assert output =~ "invalid_disposable_database_path"
    assert output =~ ~s("application_started":false)
    assert File.read!(outside) == original_bytes
    assert_sentinel_database_unchanged!(outside, marker)
  end

  test "runtime refuses a symlink database target before touching target bytes" do
    suffix = System.unique_integer([:positive])
    target = "/tmp/e2e-target-sentinel-#{suffix}.db"
    link = "/tmp/adaptive-home-coach-e2e-symlink-#{suffix}.db"
    marker = "symlink-target-must-remain"
    original_bytes = create_sentinel_database!(target, marker)
    File.ln_s!(target, link)

    on_exit(fn ->
      File.rm(link)
      clear_database_paths!(target)
    end)

    {output, status} = run_fixture_process("published-plan", link)

    assert status == 4
    assert output =~ "invalid_disposable_database_path"
    assert output =~ ~s("application_started":false)
    assert File.read!(target) == original_bytes
    assert_sentinel_database_unchanged!(target, marker)
    assert File.lstat!(link).type == :symlink
  end

  test "runtime refuses an alternate symlinked parent before touching target bytes" do
    suffix = System.unique_integer([:positive])
    real_parent = "/tmp/e2e-real-parent-#{suffix}"
    linked_parent = "/tmp/e2e-linked-parent-#{suffix}"
    basename = "adaptive-home-coach-e2e-linked-#{suffix}.db"
    real_target = Path.join(real_parent, basename)
    linked_target = Path.join(linked_parent, basename)
    marker = "linked-parent-target-must-remain"
    File.mkdir_p!(real_parent)
    original_bytes = create_sentinel_database!(real_target, marker)
    File.ln_s!(real_parent, linked_parent)

    on_exit(fn ->
      File.rm(linked_parent)
      clear_database_paths!(real_target)
      File.rmdir(real_parent)
    end)

    {output, status} = run_fixture_process("published-plan", linked_target)

    assert status == 4
    assert output =~ "invalid_disposable_database_path"
    assert output =~ ~s("application_started":false)
    assert File.read!(real_target) == original_bytes
    assert_sentinel_database_unchanged!(real_target, marker)
  end

  test "runtime always validates the actual tmp root and ignores override variables" do
    suffix = System.unique_integer([:positive])
    alternate_root = "/tmp/e2e-ignored-root-#{suffix}"
    database = "/tmp/adaptive-home-coach-e2e-actual-root-#{suffix}.db"
    File.mkdir_p!(alternate_root)

    on_exit(fn ->
      File.rmdir(alternate_root)
      clear_database_paths!(database)
    end)

    env = fixture_env(database)
    assert_mix_ok!(["ecto.create", "--quiet"], env)
    assert_mix_ok!(["ecto.migrate", "--quiet"], env)

    {output, status} =
      run_fixture_process("published-plan", database, [
        {"E2E_ADAPTIVE_TEST_TMP_ROOT", alternate_root}
      ])

    assert status == 0, output

    report = output |> report_line!("E2E_LIBRARY_SETUP=") |> Jason.decode!()
    assert is_integer(report["user_id"])
  end

  test "fixture runtime aligns endpoint origins with the selected browser port", %{
    database: database
  } do
    port = 40_39

    script = """
    endpoint = Application.fetch_env!(:burpee_trainer, BurpeeTrainerWeb.Endpoint)
    repo = Application.fetch_env!(:burpee_trainer, BurpeeTrainer.Repo)

    IO.puts(
      Jason.encode!(%{
        url: Map.new(endpoint[:url]),
        check_origin: endpoint[:check_origin],
        repo_pool: inspect(repo[:pool])
      })
    )
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        env:
          fixture_env(database) ++
            [{"PORT", Integer.to_string(port)}, {"PHX_SERVER", "true"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    config = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert config["url"] == %{"host" => "127.0.0.1", "port" => port}
    assert config["check_origin"] == ["//127.0.0.1:#{port}", "//localhost:#{port}"]
    assert config["repo_pool"] == "DBConnection.ConnectionPool"
  end

  @tag timeout: :infinity
  test "induced failure compensates the exact user and global video lane", %{database: database} do
    env = fixture_env(database)
    assert_mix_ok!(["ecto.create", "--quiet"], env)
    assert_mix_ok!(["ecto.migrate", "--quiet"], env)

    {output, status} =
      run_fixture_process("available-video", database, [
        {"E2E_INDUCED_FAILURE_AFTER", "after-fixture-creation"}
      ])

    assert status != 0
    assert output =~ "induced fixture failure"

    _repo_pid = start_isolated_repo!(database)

    assert IsolatedMigrationRepo.query!(
             "SELECT id FROM users WHERE username LIKE 'e2e_workout_%'"
           ).rows == []

    assert IsolatedMigrationRepo.query!(
             "SELECT id FROM workout_videos WHERE filename LIKE 'e2e-available-e2e_workout_%'"
           ).rows == []

    stop_supervised(IsolatedMigrationRepo)

    report = run_mode!("available-video", env)
    assert report["video_id"] > 0
  end

  @tag timeout: :infinity
  test "failed rerun leaves a committed fixture byte-for-byte unchanged", %{database: database} do
    env = fixture_env(database)
    assert_mix_ok!(["ecto.create", "--quiet"], env)
    assert_mix_ok!(["ecto.migrate", "--quiet"], env)

    report = run_mode!("completed-history", env)
    _repo_pid = start_isolated_repo!(database)
    before = fixture_snapshot(report)
    stop_supervised(IsolatedMigrationRepo)

    {output, status} =
      run_fixture_process("completed-history", database, [
        {"E2E_INDUCED_FAILURE_AFTER", "after-fixture-creation"}
      ])

    assert status != 0
    assert output =~ "induced fixture failure"

    _repo_pid = start_isolated_repo!(database)
    assert fixture_snapshot(report) == before
    stop_supervised(IsolatedMigrationRepo)
    assert run_mode!("completed-history", env) == report
  end

  @tag timeout: :infinity
  test "cleanup requires exact identity, preserves decoys, and rolls back trigger-drop failure",
       %{database: database} do
    env = fixture_env(database)
    assert_mix_ok!(["ecto.create", "--quiet"], env)
    assert_mix_ok!(["ecto.migrate", "--quiet"], env)
    report = run_mode!("available-video", env)

    _repo_pid = start_isolated_repo!(database)
    now = "2026-08-31T00:00:00Z"

    IsolatedMigrationRepo.query!(
      """
      INSERT INTO users
        (username, password_hash, timezone, timezone_provisioned, inserted_at, updated_at)
      VALUES ('e2e_workout_not_exact', 'hash', 'Etc/UTC', 1, ?, ?)
      """,
      [now, now]
    )

    [[malformed_user_id]] = IsolatedMigrationRepo.query!("SELECT last_insert_rowid()").rows
    decoy_filename = "e2e-available-e2e_workout_#{String.duplicate("a", 15)}.mp4"

    IsolatedMigrationRepo.query!(
      """
      INSERT INTO workout_videos
        (name, filename, burpee_type, duration_sec, available, format, inserted_at)
      VALUES ('Decoy fixture-like video', ?, 'six_count', 60, 1, 'follow_along', ?)
      """,
      [decoy_filename, now]
    )

    [[trigger_sql]] =
      IsolatedMigrationRepo.query!(
        "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'workout_plans_draft_only_delete_trigger'"
      ).rows

    stop_supervised(IsolatedMigrationRepo)

    {malformed_output, malformed_status} = run_cleanup_process(malformed_user_id, env)
    assert malformed_status != 0
    assert malformed_output =~ "exact fixture identity"

    {failed_output, failed_status} =
      run_cleanup_process(report["user_id"], env, [
        {"E2E_CLEANUP_INDUCED_FAILURE_AFTER", "after-trigger-drop"}
      ])

    assert failed_status != 0
    assert failed_output =~ "induced cleanup failure"

    _repo_pid = start_isolated_repo!(database)
    assert IsolatedMigrationRepo.get!(User, report["user_id"])
    assert IsolatedMigrationRepo.get!(WorkoutVideo, report["video_id"])
    assert IsolatedMigrationRepo.get!(User, malformed_user_id)
    assert IsolatedMigrationRepo.get_by!(WorkoutVideo, filename: decoy_filename)

    assert IsolatedMigrationRepo.query!(
             "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'workout_plans_draft_only_delete_trigger'"
           ).rows == [[trigger_sql]]

    stop_supervised(IsolatedMigrationRepo)

    assert run_cleanup!(report["user_id"], env)["status"] == "deleted"

    _repo_pid = start_isolated_repo!(database)

    assert IsolatedMigrationRepo.query!(
             "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'workout_plans_draft_only_delete_trigger'"
           ).rows == [[trigger_sql]]

    stop_supervised(IsolatedMigrationRepo)

    assert run_cleanup!(report["user_id"], env)["status"] == "already_absent"

    _repo_pid = start_isolated_repo!(database)
    assert IsolatedMigrationRepo.get!(User, malformed_user_id)
    assert IsolatedMigrationRepo.get_by!(WorkoutVideo, filename: decoy_filename)

    assert IsolatedMigrationRepo.query!(
             "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'workout_plans_draft_only_delete_trigger'"
           ).rows == [[trigger_sql]]

    stop_supervised(IsolatedMigrationRepo)
  end

  test "fixture entrypoint rejects unknown modes" do
    source = File.read!(@script)
    assert source =~ Enum.join(@modes, "|")

    {output, status} =
      System.cmd("mix", ["run", @script, "--", "unknown"],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "unsupported fixture mode"
  end

  test "canonical setup, verification, and cleanup scripts consume final fixture contracts" do
    setup = File.read!("scripts/e2e/setup.exs")
    verify = File.read!("scripts/e2e/verify.exs")
    cleanup = File.read!("scripts/e2e/cleanup.exs")

    assert setup =~ "library_setup.exs"
    assert setup =~ "started-plan-session"
    refute setup =~ "defining" <> " legacy workout"

    for field <-
          ~w[
            plan_id workout_video_id display_name_snapshot workout_type_snapshot program_snapshot
            video_snapshot completed_at
            burpee_count_planned duration_sec_planned note_pre note_post mood context_low_energy
            context_high_energy context_heat_affected primary_limiter preference_feedback
            capture_mode cadence_ms target_pace_sec pace_consistency pose_capture_run_status
            pose_capture_chunk_count pose_capture_chunk_indexes pose_capture_chunk_digests
          ] do
      assert verify =~ field
    end

    for source <- [verify, cleanup] do
      assert source =~ "adaptive_e2e_fixture"
      assert source =~ "adaptive-home-coach-e2e-"
    end

    assert cleanup =~ "recommendations:"
    assert cleanup =~ "drafts:"
    assert cleanup =~ "videos:"
    assert cleanup =~ ~S|~r/^e2e_workout_[0-9a-f]{16}$/|
    assert cleanup =~ ~S|owned_video_filename = "e2e-available-#{user.username}.mp4"|
  end

  defp insert_completed_pose_evidence!(completed) do
    started_at = ~U[2026-08-31 00:00:00Z]

    run =
      %PoseCaptureRun{
        user_id: completed["user_id"],
        workout_session_id: completed["session_id"],
        status: :active
      }
      |> PoseCaptureRun.start_changeset(%{"started_at" => started_at})
      |> IsolatedMigrationRepo.insert!()

    for index <- [2, 0] do
      %PoseTraceChunk{pose_capture_run_id: run.id}
      |> PoseTraceChunk.changeset(%{
        "segment" => "main",
        "chunk_index" => index,
        "started_at_ms" => index * 1_000,
        "ended_at_ms" => index * 1_000 + 500,
        "sample_count" => 1,
        "payload_json" => Jason.encode!(%{"samples" => [%{"tMs" => index * 1_000}]})
      })
      |> IsolatedMigrationRepo.insert!()
    end

    run
    |> PoseCaptureRun.complete_changeset(%{"completed_at" => started_at})
    |> IsolatedMigrationRepo.update!()
  end

  defp fixture_snapshot(report) do
    user_id = report["user_id"]
    username = report["username"]
    video_filename = "e2e-available-#{username}.mp4"

    %{
      user: IsolatedMigrationRepo.query!("SELECT * FROM users WHERE id = ?", [user_id]).rows,
      plans:
        IsolatedMigrationRepo.query!(
          "SELECT * FROM workout_plans WHERE user_id = ? ORDER BY id",
          [user_id]
        ).rows,
      recommendations:
        IsolatedMigrationRepo.query!(
          "SELECT * FROM coach_recommendations WHERE user_id = ? ORDER BY id",
          [user_id]
        ).rows,
      sessions:
        IsolatedMigrationRepo.query!(
          "SELECT * FROM workout_sessions WHERE user_id = ? ORDER BY id",
          [user_id]
        ).rows,
      videos:
        IsolatedMigrationRepo.query!(
          "SELECT * FROM workout_videos WHERE filename = ? ORDER BY id",
          [video_filename]
        ).rows,
      sequences: IsolatedMigrationRepo.query!("SELECT * FROM sqlite_sequence ORDER BY name").rows
    }
  end

  defp create_sentinel_database!(path, marker) do
    clear_database_paths!(path)
    _repo_pid = start_isolated_repo!(path)
    IsolatedMigrationRepo.query!("CREATE TABLE path_sentinel (value TEXT NOT NULL)")
    IsolatedMigrationRepo.query!("INSERT INTO path_sentinel (value) VALUES (?)", [marker])
    stop_supervised(IsolatedMigrationRepo)
    File.read!(path)
  end

  defp assert_sentinel_database_unchanged!(path, marker) do
    _repo_pid = start_isolated_repo!(path)
    assert IsolatedMigrationRepo.query!("SELECT value FROM path_sentinel").rows == [[marker]]

    assert IsolatedMigrationRepo.query!(
             "SELECT name FROM sqlite_master WHERE name = 'schema_migrations'"
           ).rows == []

    stop_supervised(IsolatedMigrationRepo)
  end

  defp clear_database_paths!(database) do
    clear_paths!(Enum.map(["", "-shm", "-wal"], &(database <> &1)))
  end

  defp run_mode!(mode, env) do
    {output, status} =
      System.cmd("mix", ["run", @script, "--", mode], env: env, stderr_to_stdout: true)

    assert status == 0, output
    output |> report_line!("E2E_LIBRARY_SETUP=") |> Jason.decode!()
  end

  defp run_script_report!(script, arguments, env, prefix) do
    {output, status} =
      System.cmd("mix", ["run", script, "--" | arguments], env: env, stderr_to_stdout: true)

    assert status == 0, output
    output |> report_line!(prefix) |> Jason.decode!()
  end

  defp run_cleanup!(user_id, env) do
    run_script_report!(
      "scripts/e2e/cleanup.exs",
      [Integer.to_string(user_id)],
      env,
      "E2E_CLEANUP="
    )
  end

  defp run_cleanup_process(user_id, env, extra_env \\ []) do
    System.cmd("mix", ["run", "scripts/e2e/cleanup.exs", "--", Integer.to_string(user_id)],
      env: env ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp start_isolated_repo!(database) do
    start_supervised!(
      {IsolatedMigrationRepo,
       database: database, pool_size: 1, journal_mode: :delete, busy_timeout: 10_000}
    )
  end

  defp assert_persisted_report!("published-plan", report) do
    plan = IsolatedMigrationRepo.get!(WorkoutPlan, report["plan_id"])
    assert plan.user_id == report["user_id"]
    assert plan.user_id == report["plan_user_id"]
    assert Atom.to_string(plan.state) == report["plan_state"]
    assert Atom.to_string(plan.origin) == report["plan_origin"]
    assert plan.name == report["plan_name"]
    assert plan.definition_json == report["definition_json"]
    assert plan.program_json == report["program_json"]
    assert plan.content_hash == report["content_hash"]
  end

  defp assert_persisted_report!("pending-candidate", report) do
    recommendation =
      IsolatedMigrationRepo.get!(CoachRecommendation, report["recommendation_id"])

    assert recommendation.user_id == report["user_id"]
    assert recommendation.selected_workout_plan_id == report["selected_workout_plan_id"]
    assert recommendation.pending_draft_id == report["pending_draft_id"]
    assert recommendation.slot_key == report["slot_key"]
    assert Date.to_iso8601(recommendation.slot_date) == report["slot_date"]

    draft = IsolatedMigrationRepo.get!(WorkoutPlan, report["pending_draft_id"])
    assert draft.user_id == report["user_id"]
    assert draft.user_id == report["pending_draft_user_id"]
    assert Atom.to_string(draft.state) == report["pending_draft_state"]
    assert draft.definition_json == report["pending_draft_definition_json"]
    assert draft.program_json == report["pending_draft_program_json"]
    assert draft.content_hash == report["pending_draft_content_hash"]
  end

  defp assert_persisted_report!("available-video", report) do
    video = IsolatedMigrationRepo.get!(WorkoutVideo, report["video_id"])
    assert video.name == report["video_name"]
    assert video.filename == report["video_filename"]
    assert video.available == report["video_available"]

    expected_snapshot = %{
      "name" => video.name,
      "filename" => video.filename,
      "type" => Atom.to_string(video.burpee_type),
      "duration" => video.duration_sec,
      "count" => video.burpee_count,
      "format" => Atom.to_string(video.format)
    }

    assert report["video_snapshot"] == expected_snapshot
    assert {:ok, ^expected_snapshot, content_hash} = ProgramHash.video_snapshot(expected_snapshot)
    assert content_hash == report["content_hash"]
  end

  defp assert_persisted_report!(mode, report)
       when mode in ["started-plan-session", "completed-history"] do
    plan = IsolatedMigrationRepo.get!(WorkoutPlan, report["plan_id"])
    session = IsolatedMigrationRepo.get!(WorkoutSession, report["session_id"])

    assert plan.user_id == report["user_id"]
    assert plan.definition_json == report["plan_definition_json"]
    assert plan.program_json == report["plan_program_json"]
    assert plan.content_hash == report["plan_content_hash"]
    assert session.user_id == report["user_id"]
    assert session.user_id == report["session_user_id"]
    assert session.plan_id == plan.id
    assert Atom.to_string(session.state) == report["session_state"]
    assert Atom.to_string(session.source_kind) == report["source_kind"]
    assert session.client_session_id == report["client_session_id"]
    assert session.content_hash == report["content_hash"]
    assert session.content_hash == plan.content_hash
    assert session.display_name_snapshot == report["display_name_snapshot"]
    assert session.display_name_snapshot == plan.name
    assert Atom.to_string(session.workout_type_snapshot) == report["workout_type_snapshot"]
    assert session.program_snapshot == report["program_snapshot"]
    assert session.program_snapshot == plan.program_json
    assert is_nil(session.video_snapshot)
    assert is_nil(report["video_snapshot"])

    if mode == "completed-history" do
      assert session.burpee_count_actual == report["burpee_count_actual"]
      assert session.duration_sec_actual == report["duration_sec_actual"]
      assert Atom.to_string(session.preference_feedback) == report["preference_feedback"]
      assert DateTime.to_iso8601(session.completed_at) == report["completed_at"]
    else
      assert is_nil(session.completed_at)
    end
  end

  defp assert_persisted_report!("provider-failure", report) do
    recommendation =
      IsolatedMigrationRepo.get!(CoachRecommendation, report["recommendation_id"])

    selected = IsolatedMigrationRepo.get!(WorkoutPlan, report["selected_workout_plan_id"])
    assert recommendation.user_id == report["user_id"]
    assert recommendation.user_id == report["recommendation_user_id"]
    assert recommendation.selected_workout_plan_id == selected.id
    assert is_nil(selected.user_id)
    assert Atom.to_string(selected.state) == report["selected_plan_state"]
    assert selected.content_hash == report["selected_plan_content_hash"]
    assert report["provider_enabled"] == false
    assert report["provider_result"] == "provider_unavailable"
    assert report["provider_request_count"] == 0
    assert report["fallback_available"] == true
  end

  defp run_fixture_process(mode, database, extra_env \\ []) do
    System.cmd("mix", ["run", @script, "--", mode],
      env: fixture_env(database) ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp fixture_env(database) do
    [
      {"MIX_ENV", "test"},
      {"E2E_ADAPTIVE_FIXTURE", "1"},
      {"E2E_ADAPTIVE_DATABASE_PATH", database},
      {"E2E_RUN_ID", Path.basename(database, ".db")}
    ]
  end

  defp assert_mix_ok!(arguments, env) do
    {output, status} = System.cmd("mix", arguments, env: env, stderr_to_stdout: true)
    assert status == 0, output
  end

  defp report_line!(output, prefix) do
    output
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      if String.starts_with?(line, prefix), do: String.replace_prefix(line, prefix, "")
    end)
    |> case do
      nil -> flunk("missing #{prefix} in output:\n#{output}")
      report -> report
    end
  end

  defp clear_paths!(paths) do
    Enum.each(paths, fn path ->
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> raise "cannot clear disposable E2E path #{path}: #{inspect(reason)}"
      end
    end)
  end
end
