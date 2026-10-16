defmodule BurpeeTrainer.TestSupport.MigrationEquivalence do
  @moduledoc false
  alias BurpeeTrainer.TestSupport.IsolatedMigrationRepo, as: Repo

  @master_versions [
    20_260_520_000_001,
    20_260_520_000_002,
    20_260_520_000_003,
    20_260_520_000_004,
    20_260_520_000_005,
    20_260_521_000_000,
    20_260_528_220_847,
    20_260_529_000_000,
    20_260_530_215_059,
    20_260_608_173_149,
    20_260_608_190_935,
    20_260_608_194_816,
    20_260_618_232_445,
    20_260_701_212_039,
    20_260_702_080_349,
    20_260_702_120_741,
    20_260_802_105_541,
    20_260_814_205_427,
    20_260_817_230_052,
    20_260_908_000_000
  ]

  @now "2026-09-01T00:00:00Z"

  def seed_upstream!(repo) do
    repo.query!(
      "INSERT INTO users (username, oidc_sub, inserted_at, updated_at) VALUES ('one', 'seed-one', ?, ?), ('two', 'seed-two', ?, ?)",
      [@now, @now, @now, @now]
    )

    repo.query!(
      "INSERT INTO goals (user_id, burpee_type, burpee_count_target, duration_sec_target, date_target, burpee_count_baseline, duration_sec_baseline, date_baseline, status, inserted_at, updated_at) VALUES (1, 'six_count', 20, 180, '2026-10-01', 10, 120, '2026-09-01', 'active', ?, ?)",
      [@now, @now]
    )

    [[goal]] = repo.query!("SELECT id FROM goals").rows

    program =
      Jason.encode!(%{
        "events" => [%{"kind" => "work", "reps" => 20}],
        "semantics" => %{"pacing_style" => "even"}
      })

    repo.query!(
      "INSERT INTO execution_programs (content_hash, schema_version, solver_version, burpee_type, target_reps, target_duration_sec, event_count, program_json, summary_json, inserted_at, updated_at) VALUES ('seed-program', 2, 4, 'six_count', 20, 180, 1, json(?), json('{}'), ?, ?)",
      [program, @now, @now]
    )

    [[program_id]] = repo.query!("SELECT id FROM execution_programs").rows

    repo.query!(
      "INSERT INTO workout_plans (user_id, name, burpee_type, style_name, target_duration_min, burpee_count_target, sec_per_burpee, pacing_style, fatigue_factor, source_json, current_execution_program_id, inserted_at, updated_at) VALUES (1, 'Seed plan', 'six_count', 'steady', 3, 20, 9.0, 'even', 0.0, json('{}'), ?, ?, ?)",
      [program_id, @now, @now]
    )

    [[plan]] = repo.query!("SELECT id FROM workout_plans").rows

    repo.query!(
      "INSERT INTO workout_videos (name, filename, burpee_type, duration_sec, burpee_count, inserted_at) VALUES ('Seed video', 'seed.mp4', 'six_count', 120, 12, ?)",
      [@now]
    )

    [[video]] = repo.query!("SELECT id FROM workout_videos").rows

    repo.query!(
      "INSERT INTO workout_sessions (user_id, plan_id, execution_program_id, goal_id, burpee_type, burpee_count_planned, duration_sec_planned, burpee_count_actual, duration_sec_actual, status, source, reported_at, inserted_at, updated_at) VALUES (1, ?, ?, ?, 'six_count', 20, 180, 20, 180, 'reported', 'plan', ?, ?, ?), (1, ?, ?, NULL, 'six_count', 12, 120, 12, 120, 'reported', 'video', ?, ?, ?), (1, ?, ?, NULL, 'six_count', 20, 180, NULL, NULL, 'running', 'plan', NULL, ?, ?)",
      [
        plan,
        program_id,
        goal,
        @now,
        @now,
        @now,
        video,
        program_id,
        @now,
        @now,
        @now,
        plan,
        program_id,
        @now,
        @now
      ]
    )

    [[completed_plan], [completed_video], [abandoned]] =
      repo.query!("SELECT id FROM workout_sessions ORDER BY id").rows

    repo.query!(
      "UPDATE workout_sessions SET video_id = ?, execution_program_id = NULL WHERE id = ?",
      [video, completed_video]
    )

    repo.query!(
      "INSERT INTO pose_capture_runs (user_id, plan_id, workout_session_id, status, capture_version, started_at, completed_at, inserted_at, updated_at) VALUES (1, ?, ?, 'completed', 1, ?, ?, ?, ?), (1, ?, ?, 'active', 1, ?, NULL, ?, ?)",
      [plan, completed_plan, @now, @now, @now, @now, plan, abandoned, @now, @now, @now]
    )

    [[completed_run], [active_run]] =
      repo.query!("SELECT id FROM pose_capture_runs ORDER BY id").rows

    repo.query!(
      "INSERT INTO pose_trace_chunks (pose_capture_run_id, segment, chunk_index, started_at_ms, ended_at_ms, sample_count, payload_json, payload_digest, inserted_at, updated_at) VALUES (?, 'main', 0, 0, 1000, 1, '{\"rep\":1}', 'digest', ?, ?)",
      [completed_run, @now, @now]
    )

    [[completed_chunk]] = repo.query!("SELECT id FROM pose_trace_chunks").rows

    # Abandoned video is on another user because upstream allows one live session per user.
    repo.query!(
      "INSERT INTO workout_sessions (user_id, video_id, burpee_type, status, source, inserted_at, updated_at) VALUES (2, ?, 'six_count', 'running', 'video', ?, ?)",
      [video, @now, @now]
    )

    repo.query!(
      "INSERT INTO pose_trace_chunks (pose_capture_run_id, segment, chunk_index, started_at_ms, ended_at_ms, sample_count, payload_json, payload_digest, inserted_at, updated_at) VALUES (?, 'main', 0, 0, 1000, 1, '{\"active\":true}', 'active-digest', ?, ?)",
      [active_run, @now, @now]
    )

    # Keep every retained source content field non-default where feasible.
    repo.query!(
      "UPDATE workout_sessions SET client_session_id = 'completed-token', note_pre = 'before', note_post = 'after', mood = 4, tags = '[\"seed\"]', capture_mode = 'tracked', cadence_ms = '[9000,9000]', target_pace_sec = 9.0, pace_consistency = 0.9, style_name = 'steady', rate_per_min_actual = 6.7, days_since_last = 2, rate_delta = 0.2, rate_avg_rolling_3 = 6.5, time_of_day_bucket = 'morning' WHERE id = ?",
      [completed_plan]
    )

    repo.query!(
      "INSERT INTO user_stats (user_id, previous_best_weeks, previous_best_ended_on, updated_at, best_week_pushups, best_week_pushups_on, best_session_pushups, best_session_pushups_on, best_pace_sec_per_burpee, best_pace_on, lifetime_pushup_milestone) VALUES (1, 3, '2026-08-01', ?, 100, '2026-08-01', 40, '2026-08-01', 8.5, '2026-08-01', 500)",
      [@now]
    )

    repo.query!(
      "INSERT INTO style_performances (user_id, style_name, burpee_type, mood, level, time_of_day_bucket, inserted_at, updated_at) VALUES (1, 'steady', 'six_count', 4, 'starter', 'morning', ?, ?)",
      [@now, @now]
    )

    # Unlinked completed plan execution preserves a Historical display name and program.
    repo.query!(
      "INSERT INTO workout_sessions (user_id, execution_program_id, burpee_type, burpee_count_actual, duration_sec_actual, inserted_at, updated_at) VALUES (2, ?, 'six_count', 8, 80, ?, ?)",
      [program_id, @now, @now]
    )

    # Completed manual history has no program/video snapshot, but its actual facts survive.
    repo.query!(
      "INSERT INTO workout_sessions (user_id, burpee_type, burpee_count_actual, duration_sec_actual, note_post, inserted_at, updated_at) VALUES (2, 'navy_seal', 5, 75, 'manual history', ?, ?)",
      [@now, @now]
    )

    # NULL count is legal video snapshot evidence and must not become zero.
    repo.query!(
      "INSERT INTO workout_videos (name, filename, burpee_type, duration_sec, inserted_at) VALUES ('Unknown-count video', 'nil-count.mp4', 'navy_seal', 300, ?)",
      [@now]
    )

    repo.query!(
      "INSERT INTO workout_sessions (user_id, video_id, burpee_type, burpee_count_actual, duration_sec_actual, reported_at, inserted_at, updated_at) VALUES (2, 2, 'navy_seal', 20, 300, ?, ?, ?)",
      [@now, @now, @now]
    )

    # Completed orphan capture survives with session link nil if abandoned history is removed.
    repo.query!(
      "INSERT INTO pose_capture_runs (user_id, workout_session_id, status, started_at, completed_at, inserted_at, updated_at) VALUES (2, 4, 'completed', ?, ?, ?, ?)",
      [@now, @now, @now, @now]
    )

    # Deleted IDs must not be reused: independently exercise every retained sequence.
    for table <-
          ~w[users goals user_stats workout_videos workout_plans workout_sessions pose_capture_runs pose_trace_chunks] do
      repo.query!("UPDATE sqlite_sequence SET seq = 1000 WHERE name = ?", [table])
    end

    %{
      program: program,
      plan: plan,
      video: video,
      abandoned: abandoned,
      completed_run: completed_run,
      active_run: active_run,
      goal: goal,
      completed_plan: completed_plan,
      completed_video: completed_video,
      completed_chunk: completed_chunk
    }
  end

  def upstream?(version), do: version in @master_versions

  def migrations(dir) do
    dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      version =
        path |> Path.basename() |> String.split("_", parts: 2) |> hd() |> String.to_integer()

      {:defmodule, _, [{:__aliases__, _, parts}, _]} =
        path |> File.read!() |> Code.string_to_quoted!()

      module = Module.concat(parts)
      unless Code.ensure_loaded?(module), do: Code.require_file(path)
      [{version, module}]
    end)
  end

  def with_db(fun, options \\ []) do
    path =
      Path.join(
        System.tmp_dir!(),
        "coach-first-equivalence-#{Ecto.UUID.generate()}.db"
      )

    supervised? = Keyword.get(options, :supervised?, true)

    repo_options = [
      database: path,
      pool_size: Keyword.get(options, :pool_size, 1),
      journal_mode: :delete
    ]

    pid =
      if supervised? do
        ExUnit.Callbacks.start_supervised!({Repo, repo_options})
      else
        {:ok, pid} = Repo.start_link(repo_options)
        pid
      end

    try do
      fun.(Repo)
    after
      if supervised?, do: ExUnit.Callbacks.stop_supervised!(Repo), else: GenServer.stop(pid)
      Enum.each(["", "-wal", "-shm"], &File.rm(path <> &1))
    end
  end

  def fingerprint(repo) do
    rows =
      repo.query!(
        "SELECT type, name, tbl_name, COALESCE(sql, '') FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name, tbl_name"
      ).rows

    payload =
      Enum.map_join(rows, "\n", fn row ->
        Enum.map_join(row, "\u001F", fn value ->
          value |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
        end)
      end)

    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  def dump(repo) do
    tables =
      repo.query!(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT IN ('schema_migrations', 'sqlite_sequence') ORDER BY name"
      ).rows
      |> List.flatten()

    %{
      schema: schema(repo),
      data:
        Map.new(tables, fn table ->
          columns =
            repo.query!("PRAGMA table_info(\"#{table}\")").rows
            |> Enum.map(&Enum.at(&1, 1))
            |> Enum.sort()

          quoted = Enum.map_join(columns, ", ", &"\"#{&1}\"")
          {table, repo.query!("SELECT #{quoted} FROM \"#{table}\" ORDER BY #{quoted}").rows}
        end),
      sequences: repo.query!("SELECT name, seq FROM sqlite_sequence ORDER BY name").rows
    }
  end

  defp schema(repo) do
    repo.query!(
      "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND name != 'schema_migrations' ORDER BY type, name, tbl_name"
    ).rows
    |> Enum.map(fn
      ["table", "users", table, sql] ->
        ["table", "users", table, normalize_users_sql(sql)]

      row ->
        row
    end)
  end

  # Split only top-level CREATE TABLE clauses. Quoted strings/identifiers and
  # nested expressions stay byte-for-byte intact; only column-list order changes.
  def normalize_users_sql(sql) do
    {prefix, "(" <> body} = String.split_at(sql, :binary.match(sql, "(") |> elem(0))
    {clauses, suffix} = clauses(String.graphemes(body), 0, nil, [], [])
    {prefix, Enum.sort(clauses), suffix}
  end

  defp clauses([], _depth, _quote, _current, _clauses),
    do: raise("unterminated CREATE TABLE")

  defp clauses([quote, quote | rest], depth, quote, current, parts),
    do: clauses(rest, depth, quote, [quote, quote | current], parts)

  defp clauses([quote | rest], depth, quote, current, parts),
    do: clauses(rest, depth, nil, [quote | current], parts)

  defp clauses([char | rest], depth, quote, current, parts) when not is_nil(quote),
    do: clauses(rest, depth, quote, [char | current], parts)

  defp clauses([char | rest], depth, nil, current, parts) when char in ["'", "\"", "`", "["],
    do: clauses(rest, depth, if(char == "[", do: "]", else: char), [char | current], parts)

  defp clauses(["(" | rest], depth, nil, current, parts),
    do: clauses(rest, depth + 1, nil, ["(" | current], parts)

  defp clauses([")" | rest], 0, nil, current, parts),
    do: {[finish_clause(current) | parts], ")" <> Enum.join(rest)}

  defp clauses([")" | rest], depth, nil, current, parts),
    do: clauses(rest, depth - 1, nil, [")" | current], parts)

  defp clauses(["," | rest], 0, nil, current, parts),
    do: clauses(rest, 0, nil, [], [finish_clause(current) | parts])

  defp clauses([char | rest], depth, nil, current, parts),
    do: clauses(rest, depth, nil, [char | current], parts)

  defp finish_clause(current), do: current |> Enum.reverse() |> Enum.join() |> String.trim()
end
