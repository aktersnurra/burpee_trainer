defmodule BurpeeTrainer.DeletionFirstMigrationTest do
  use BurpeeTrainer.DataCase, async: false

  alias BurpeeTrainer.PlanCompiler.ProgramHash
  alias BurpeeTrainer.TestFixtures.DeletionFirstFallback
  alias BurpeeTrainer.TestSupport.IsolatedMigrationRepo

  @legacy_version 20_260_827_200_641
  @migration_dir Path.expand("../../priv/repo/migrations", __DIR__)
  @migration_glob Path.join(@migration_dir, "*_rebuild_workout_library.exs")

  @doc false
  def rehearsal_source_version, do: @legacy_version

  @doc false
  def seed_rehearsal_source!(repo) do
    facts = seed_raw_rows(repo)
    :ok = assert_seed_baseline!(repo, facts)
    facts
  end

  @doc false
  def rehearsal_normalized_facts(repo), do: normalized_facts(repo)

  @doc false
  def rehearsal_source_snapshot(repo), do: predecessor_snapshot(repo)

  @doc false
  def verify_rehearsal_forward!(repo, before, facts) do
    :ok = assert_post_migration!(repo, before, facts)
    :ok = assert_fallback_literals!(repo)
    :ok = assert_final_constraints!(repo, facts)
    assert repo.query!("PRAGMA foreign_keys").rows == [[1]]
    assert repo.query!("PRAGMA foreign_key_check").rows == []
    assert helper_tables(repo) == []
    :ok
  end

  test "generated migration freezes fallback literals without runtime domain references" do
    assert [migration_file] = Path.wildcard(@migration_glob)
    source = File.read!(migration_file)

    assert source =~ Jason.encode!(DeletionFirstFallback.definition_json())
    assert source =~ Jason.encode!(DeletionFirstFallback.program_json())
    assert source =~ DeletionFirstFallback.definition_hash()
    assert source =~ DeletionFirstFallback.content_hash()
    refute source =~ "PlanCompiler"
    refute source =~ "ProgramHash"
    refute source =~ "DeletionFirstFallback"
  end

  test "partial and altered source schemas fail closed without recording the version" do
    with_isolated_repo(fn repo ->
      repo.query!("CREATE TABLE workout_sessions_rebuilt (id INTEGER PRIMARY KEY)")
      assert_terminal_retry_rejected!(repo)
    end)

    with_isolated_repo(fn repo ->
      repo.query!("DROP INDEX workout_sessions_user_id_index")
      assert_terminal_retry_rejected!(repo)
    end)
  end

  test "partial target schemas with a missing index or dummy trigger fail closed" do
    with_final_migration_repo(fn repo, _migrations, _migration_version, _facts ->
      repo.query!("DROP INDEX workout_sessions_user_id_client_session_id_index")
      assert_terminal_retry_rejected!(repo)
    end)

    with_final_migration_repo(fn repo, _migrations, _migration_version, _facts ->
      repo.checkout(
        fn ->
          repo.query!("DROP INDEX workout_sessions_user_id_client_session_id_index")

          repo.query!("""
          CREATE INDEX workout_sessions_user_id_client_session_id_index
          ON workout_sessions (client_session_id)
          """)
        end,
        timeout: :infinity
      )

      assert_terminal_retry_rejected!(repo)
    end)

    with_final_migration_repo(fn repo, _migrations, _migration_version, _facts ->
      repo.query!("DROP TRIGGER workout_sessions_identity_snapshot_immutable_trigger")

      repo.query!("""
      CREATE TRIGGER workout_sessions_identity_snapshot_immutable_trigger
      BEFORE UPDATE ON workout_sessions
      BEGIN
        SELECT 1;
      END
      """)

      assert_terminal_retry_rejected!(repo)
    end)

    with_final_migration_repo(fn repo, _migrations, _migration_version, _facts ->
      repo.query!("DROP INDEX workout_plans_content_hash_index")

      repo.query!("""
      CREATE UNIQUE INDEX workout_plans_content_hash_index
      ON workout_plans (content_hash)
      """)

      assert_terminal_retry_rejected!(repo)
    end)
  end

  test "target table with incorrect constraints fails closed" do
    with_final_migration_repo(fn repo, _migrations, _migration_version, _facts ->
      dependent_sql =
        repo.query!("""
        SELECT sql FROM sqlite_master
        WHERE tbl_name = 'coach_recommendations' AND type IN ('index', 'trigger')
        ORDER BY type, name
        """).rows
        |> List.flatten()

      repo.checkout(
        fn ->
          repo.query!("PRAGMA foreign_keys = OFF")
          repo.query!("DROP TABLE coach_recommendations")

          repo.query!("""
          CREATE TABLE coach_recommendations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            slot_key TEXT NOT NULL,
            slot_date TEXT NOT NULL,
            selected_workout_plan_id INTEGER,
            selected_workout_video_id INTEGER,
            pending_draft_id INTEGER,
            rationale TEXT,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
          """)

          Enum.each(dependent_sql, &repo.query!/1)
          repo.query!("PRAGMA foreign_keys = ON")
        end,
        timeout: :infinity
      )

      assert_terminal_retry_rejected!(repo)
    end)
  end

  test "target retry rejects invalid row facts and regressed sequences" do
    with_final_migration_repo(fn repo, _migrations, _migration_version, facts ->
      session_trigger_sql = schema_object_sql(repo, "trigger", "workout_sessions")

      repo.checkout(
        fn ->
          Enum.each(session_trigger_sql, fn {name, _sql} ->
            repo.query!("DROP TRIGGER #{name}")
          end)

          repo.query!("PRAGMA ignore_check_constraints = ON")

          repo.query!("UPDATE workout_sessions SET state = 'invalid' WHERE id = ?", [
            facts.structured_session_id
          ])

          repo.query!("PRAGMA ignore_check_constraints = OFF")
          Enum.each(session_trigger_sql, fn {_name, sql} -> repo.query!(sql) end)
        end,
        timeout: :infinity
      )

      assert_terminal_retry_rejected!(repo)
    end)

    with_final_migration_repo(fn repo, _migrations, _migration_version, facts ->
      now = "2026-08-31T00:00:00Z"
      [[fallback_id]] = repo.query!("SELECT id FROM workout_plans WHERE origin = 'built_in'").rows

      [[fallback_program]] =
        repo.query!("SELECT program_json FROM workout_plans WHERE id = ?", [fallback_id]).rows

      draft_id =
        insert_id(
          repo,
          """
          INSERT INTO workout_plans (
            user_id, name, origin, state, definition_json, program_json,
            content_hash, burpee_type, inserted_at, updated_at
          ) VALUES (?, 'Fact invariant draft', 'user', 'draft', json('{}'), json(?),
                    'fact-invariant-draft', 'six_count', ?, ?)
          """,
          [facts.user_id, fallback_program, now, now]
        )

      repo.query!(
        """
        INSERT INTO coach_recommendations (
          user_id, slot_key, slot_date, selected_workout_plan_id,
          pending_draft_id, inserted_at, updated_at
        ) VALUES (?, 'fact-invariant', '2026-08-31', ?, ?, ?, ?)
        """,
        [facts.user_id, fallback_id, draft_id, now, now]
      )

      other_user_id =
        insert_id(
          repo,
          """
          INSERT INTO users
            (username, password_hash, timezone, timezone_provisioned, inserted_at, updated_at)
          VALUES ('fact-invariant-owner', 'hash', 'Etc/UTC', 1, ?, ?)
          """,
          [now, now]
        )

      [[guard_sql]] =
        repo.query!("""
        SELECT sql FROM sqlite_master
        WHERE type = 'trigger' AND name = 'workout_plans_pending_draft_guard_trigger'
        """).rows

      repo.checkout(
        fn ->
          repo.query!("DROP TRIGGER workout_plans_pending_draft_guard_trigger")

          repo.query!("UPDATE workout_plans SET user_id = ? WHERE id = ?", [
            other_user_id,
            draft_id
          ])

          repo.query!(guard_sql)
        end,
        timeout: :infinity
      )

      assert_terminal_retry_rejected!(repo)
    end)

    with_final_migration_repo(fn repo, _migrations, _migration_version, _facts ->
      repo.query!("UPDATE sqlite_sequence SET seq = 0 WHERE name = 'workout_sessions'")
      assert_terminal_retry_rejected!(repo)
    end)
  end

  test "target retry rejects a video session with a mismatched workout type snapshot" do
    with_final_migration_repo(fn repo, _migrations, _migration_version, facts ->
      session_trigger_sql = schema_object_sql(repo, "trigger", "workout_sessions")

      repo.checkout(
        fn ->
          Enum.each(session_trigger_sql, fn {name, _sql} ->
            repo.query!("DROP TRIGGER #{name}")
          end)

          repo.query!("PRAGMA ignore_check_constraints = ON")

          repo.query!(
            "UPDATE workout_sessions SET workout_type_snapshot = 'navy_seal' WHERE id = ?",
            [facts.nil_count_video_session_id]
          )

          repo.query!("PRAGMA ignore_check_constraints = OFF")
          Enum.each(session_trigger_sql, fn {_name, sql} -> repo.query!(sql) end)
        end,
        timeout: :infinity
      )

      assert_terminal_retry_rejected!(repo)
    end)
  end

  test "selected recommendation sources restrict deletion instead of violating selection shape" do
    with_final_migration_repo(fn repo, _migrations, _migration_version, facts ->
      recommendation_sql = table_sql(repo, "coach_recommendations")
      assert recommendation_sql =~ "REFERENCES workout_plans(id) ON DELETE RESTRICT"
      assert recommendation_sql =~ "REFERENCES workout_videos(id) ON DELETE RESTRICT"

      now = "2026-08-30T03:00:00Z"
      [[fallback_program]] = repo.query!("SELECT program_json FROM workout_plans LIMIT 1").rows

      draft_id =
        insert_id(
          repo,
          """
          INSERT INTO workout_plans (
            user_id, name, origin, state, definition_json, program_json,
            content_hash, burpee_type, target_reps, target_duration_sec,
            inserted_at, updated_at
          ) VALUES (?, 'Selected draft', 'user', 'draft', json('{}'), json(?),
                    'selected-draft-hash', 'six_count', 10, 120, ?, ?)
          """,
          [facts.user_id, fallback_program, now, now]
        )

      video_id =
        insert_final_video!(repo, %{
          "name" => "Selected video",
          "filename" => "selected-video.mp4",
          "type" => "six_count",
          "duration" => 120,
          "count" => 10,
          "format" => "follow_along"
        })

      repo.query!(
        """
        INSERT INTO coach_recommendations (
          user_id, slot_key, slot_date, selected_workout_plan_id, inserted_at, updated_at
        ) VALUES (?, 'selected-plan-delete', '2026-08-30', ?, ?, ?)
        """,
        [facts.user_id, draft_id, now, now]
      )

      repo.query!(
        """
        INSERT INTO coach_recommendations (
          user_id, slot_key, slot_date, selected_workout_video_id, inserted_at, updated_at
        ) VALUES (?, 'selected-video-delete', '2026-08-30', ?, ?, ?)
        """,
        [facts.user_id, video_id, now, now]
      )

      assert_raise Exqlite.Error, ~r/FOREIGN KEY constraint failed/, fn ->
        repo.query!("DELETE FROM workout_plans WHERE id = ?", [draft_id])
      end

      assert_raise Exqlite.Error, ~r/FOREIGN KEY constraint failed/, fn ->
        repo.query!("DELETE FROM workout_videos WHERE id = ?", [video_id])
      end

      assert repo.query!("SELECT COUNT(*) FROM coach_recommendations WHERE slot_date = ?", [
               "2026-08-30"
             ]).rows == [[2]]
    end)
  end

  test "forward atomically preserves completed facts and deletes abandoned state" do
    with_isolated_repo(fn repo ->
      facts = seed_raw_rows(repo)
      assert :ok = assert_seed_baseline!(repo, facts)
      before = normalized_facts(repo)

      assert [migration_file] = Path.wildcard(@migration_glob)
      migration_version = migration_version(migration_file)
      assert migration_version > @legacy_version
      migrations = isolated_migrations(@migration_dir)

      _ = Ecto.Migrator.run(repo, migrations, :up, to: migration_version)
      assert :ok = assert_post_migration!(repo, before, facts)
      assert :ok = assert_fallback_literals!(repo)
      assert :ok = assert_final_constraints!(repo, facts)
      assert repo.query!("PRAGMA foreign_keys").rows == [[1]]
      assert repo.query!("PRAGMA foreign_key_check").rows == []
      assert helper_tables(repo) == []

      target_before_retry = terminal_target_snapshot(repo)
      repo.query!("DELETE FROM schema_migrations WHERE version = ?", [migration_version])
      _ = Ecto.Migrator.run(repo, migrations, :up, to: migration_version)

      assert terminal_target_snapshot(repo) == target_before_retry

      assert repo.query!("SELECT version FROM schema_migrations WHERE version = ?", [
               migration_version
             ]).rows == [[migration_version]]

      assert repo.query!("PRAGMA foreign_keys").rows == [[1]]
      assert repo.query!("PRAGMA foreign_key_check").rows == []
      assert helper_tables(repo) == []
    end)
  end

  test "down directs operators to verified backup restoration" do
    with_final_migration_repo(fn repo, migrations, _migration_version, _facts ->
      assert_raise RuntimeError,
                   ~r/irreversible migration: restore the verified pre-migration SQLite backup while the application is quiesced/,
                   fn ->
                     Ecto.Migrator.run(repo, migrations, :down, step: 1)
                   end

      assert repo.query!("PRAGMA foreign_keys").rows == [[1]]
      assert repo.query!("PRAGMA foreign_key_check").rows == []
      assert helper_tables(repo) == []
    end)
  end

  defp assert_fallback_literals!(repo) do
    assert [[definition_json, program_json, content_hash]] =
             repo.query!("""
             SELECT definition_json, program_json, content_hash
             FROM workout_plans
             WHERE origin = 'built_in' AND state = 'published'
             """).rows

    assert Jason.decode!(definition_json) == DeletionFirstFallback.definition_json()
    assert Jason.decode!(program_json) == DeletionFirstFallback.program_json()
    assert content_hash == DeletionFirstFallback.content_hash()

    video_rows =
      repo.query!("""
      SELECT video_snapshot, content_hash
      FROM workout_sessions
      WHERE source_kind = 'video'
      ORDER BY id
      """).rows

    assert Enum.all?(video_rows, fn [snapshot_json, hash] ->
             snapshot = Jason.decode!(snapshot_json)
             ProgramHash.hash_canonical_map(snapshot) == hash
           end)

    :ok
  end

  defp assert_final_constraints!(repo, facts) do
    plan_sql = table_sql(repo, "workout_plans")
    recommendation_sql = table_sql(repo, "coach_recommendations")
    session_sql = table_sql(repo, "workout_sessions")

    assert plan_sql =~ "workout_plans_origin_owner_check"
    assert plan_sql =~ "workout_plans_state_timestamp_check"
    assert :ok = assert_non_unique_content_hash_index!(repo, facts)
    assert recommendation_sql =~ "coach_recommendations_selection_check"
    assert session_sql =~ "workout_sessions_source_snapshot_check"

    trigger_names =
      repo.query!("SELECT name FROM sqlite_master WHERE type = 'trigger'").rows
      |> List.flatten()
      |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new(~w[
               workout_plans_state_transition_trigger
               workout_plans_immutable_content_update_trigger
               workout_plans_draft_only_delete_trigger
               workout_plans_pending_draft_guard_trigger
               coach_recommendations_pending_draft_insert_trigger
               coach_recommendations_pending_draft_update_trigger
               workout_sessions_live_plan_snapshot_insert_trigger
               workout_sessions_live_plan_snapshot_update_trigger
               workout_sessions_live_video_snapshot_insert_trigger
               workout_sessions_live_video_snapshot_update_trigger
               workout_sessions_state_transition_trigger
               workout_sessions_identity_snapshot_immutable_trigger
               workout_sessions_exact_once_completion_trigger
             ]),
             trigger_names
           )

    [[fallback_id]] =
      repo.query!(
        "SELECT id FROM workout_plans WHERE origin = 'built_in' AND state = 'published'"
      ).rows

    now = "2026-08-29T00:00:00Z"
    assert :ok = assert_valid_row_shapes!(repo, facts, fallback_id, now)

    assert_raise Exqlite.Error, ~r/workout_plans_origin_owner_check/, fn ->
      repo.query!(
        """
        INSERT INTO workout_plans (
          user_id, name, origin, state, definition_json, program_json,
          content_hash, burpee_type, published_at, inserted_at, updated_at
        ) VALUES (?, 'invalid owner', 'built_in', 'published', json('{}'),
                  json('{}'), 'invalid-owner-hash', 'six_count', ?, ?, ?)
        """,
        [facts.user_id, now, now, now]
      )
    end

    assert_raise Exqlite.Error, ~r/workout_plans_state_transition_check/, fn ->
      repo.query!("UPDATE workout_plans SET state = 'draft', published_at = NULL WHERE id = ?", [
        fallback_id
      ])
    end

    assert_raise Exqlite.Error, ~r/workout_plans_immutable_content_check/, fn ->
      repo.query!("UPDATE workout_plans SET name = 'changed' WHERE id = ?", [fallback_id])
    end

    assert_raise Exqlite.Error, ~r/workout_plans_draft_only_delete_check/, fn ->
      repo.query!("DELETE FROM workout_plans WHERE id = ?", [fallback_id])
    end

    assert_raise Exqlite.Error, ~r/coach_recommendations_selection_check/, fn ->
      repo.query!(
        """
        INSERT INTO coach_recommendations (
          user_id, slot_key, slot_date, selected_workout_plan_id,
          selected_workout_video_id, inserted_at, updated_at
        ) VALUES (?, 'invalid-selection', '2026-08-29', ?, ?, ?, ?)
        """,
        [facts.user_id, fallback_id, facts.prescribed_video_id, now, now]
      )
    end

    assert_raise Exqlite.Error, ~r/coach_recommendations_pending_draft_check/, fn ->
      repo.query!(
        """
        INSERT INTO coach_recommendations (
          user_id, slot_key, slot_date, selected_workout_plan_id,
          pending_draft_id, inserted_at, updated_at
        ) VALUES (?, 'invalid-draft', '2026-08-29', ?, ?, ?, ?)
        """,
        [facts.user_id, fallback_id, fallback_id, now, now]
      )
    end

    assert_raise Exqlite.Error, ~r/workout_sessions_source_snapshot_check/, fn ->
      repo.query!(
        """
        INSERT INTO workout_sessions (
          user_id, state, source_kind, burpee_type, capture_mode,
          inserted_at, updated_at
        ) VALUES (?, 'started', 'manual', 'six_count', 'logged', ?, ?)
        """,
        [facts.user_id, now, now]
      )
    end

    [[fallback_program, fallback_hash]] =
      repo.query!("SELECT program_json, content_hash FROM workout_plans WHERE id = ?", [
        fallback_id
      ]).rows

    for workout_type_snapshot <- [nil, "invalid_type"] do
      assert_raise Exqlite.Error,
                   ~r/workout_sessions_source_snapshot_check|workout_sessions_live_plan_snapshot_check/,
                   fn ->
                     repo.query!(
                       """
                       INSERT INTO workout_sessions (
                         user_id, state, source_kind, plan_id, display_name_snapshot,
                         workout_type_snapshot, program_snapshot, content_hash,
                         client_session_id, started_at, burpee_type,
                         burpee_count_planned, duration_sec_planned, capture_mode,
                         inserted_at, updated_at
                       ) VALUES (?, 'started', 'plan', ?, 'Built-in Steady 10', ?,
                                 json(?), ?, 'invalid-plan-workout-type', ?, 'six_count',
                                 10, 120, 'logged', ?, ?)
                       """,
                       [
                         facts.user_id,
                         fallback_id,
                         workout_type_snapshot,
                         fallback_program,
                         fallback_hash,
                         now,
                         now,
                         now
                       ]
                     )
                   end
    end

    assert_raise Exqlite.Error,
                 ~r/workout_sessions_source_snapshot_check|workout_sessions_live_plan_snapshot_check/,
                 fn ->
                   repo.query!(
                     """
                     INSERT INTO workout_sessions (
                       user_id, state, source_kind, plan_id, display_name_snapshot,
                       workout_type_snapshot, program_snapshot, content_hash,
                       client_session_id, started_at, burpee_type,
                       burpee_count_planned, duration_sec_planned, capture_mode,
                       inserted_at, updated_at
                     ) VALUES (?, 'started', 'plan', ?, 'Built-in Steady 10', 'six_count',
                               json(?), ?, 'mismatched-plan-workout-type', ?, 'navy_seal',
                               10, 120, 'logged', ?, ?)
                     """,
                     [facts.user_id, fallback_id, fallback_program, fallback_hash, now, now, now]
                   )
                 end

    assert_raise Exqlite.Error, ~r/workout_sessions_source_snapshot_check/, fn ->
      repo.query!(
        """
        INSERT INTO workout_sessions (
          user_id, state, source_kind, plan_id, display_name_snapshot,
          workout_type_snapshot, program_snapshot, content_hash,
          client_session_id, started_at, completed_at, burpee_type,
          burpee_count_actual, duration_sec_actual, capture_mode,
          inserted_at, updated_at
        ) VALUES (?, 'completed', 'plan', ?, 'Live plan', 'six_count',
                  NULL, NULL, NULL, NULL, ?, 'six_count', 10, 120,
                  'logged', ?, ?)
        """,
        [facts.user_id, fallback_id, now, now, now]
      )
    end

    assert_raise Exqlite.Error, ~r/workout_sessions_live_plan_snapshot_check/, fn ->
      repo.query!(
        """
        INSERT INTO workout_sessions (
          user_id, state, source_kind, plan_id, display_name_snapshot,
          workout_type_snapshot, program_snapshot, content_hash,
          client_session_id, started_at, completed_at, burpee_type,
          burpee_count_actual, duration_sec_actual, capture_mode,
          inserted_at, updated_at
        ) VALUES (?, 'completed', 'plan', ?, 'Built-in Steady 10', 'six_count',
                  json('{}'), ?, 'mismatched-live-plan', ?, ?, 'six_count',
                  10, 120, 'logged', ?, ?)
        """,
        [facts.user_id, fallback_id, fallback_hash, now, now, now, now]
      )
    end

    assert_raise Exqlite.Error, ~r/workout_sessions_source_snapshot_check/, fn ->
      repo.query!(
        """
        INSERT INTO workout_sessions (
          user_id, state, source_kind, plan_id, workout_type_snapshot,
          program_snapshot, content_hash, client_session_id, started_at,
          burpee_type, capture_mode, inserted_at, updated_at
        ) VALUES (?, 'started', 'plan', ?, 'six_count', json(?), ?,
                  'missing-plan-display', ?, 'six_count', 'logged', ?, ?)
        """,
        [facts.user_id, fallback_id, fallback_program, fallback_hash, now, now, now]
      )
    end

    [[video_snapshot, video_hash]] =
      repo.query!("SELECT video_snapshot, content_hash FROM workout_sessions WHERE id = ?", [
        facts.nil_count_video_session_id
      ]).rows

    for workout_type_snapshot <- [nil, "invalid_type"] do
      assert_raise Exqlite.Error,
                   ~r/workout_sessions_source_snapshot_check|workout_sessions_live_video_snapshot_check/,
                   fn ->
                     repo.query!(
                       """
                       INSERT INTO workout_sessions (
                         user_id, state, source_kind, workout_video_id,
                         display_name_snapshot, workout_type_snapshot, video_snapshot,
                         content_hash, client_session_id, started_at, burpee_type,
                         duration_sec_planned, capture_mode, inserted_at, updated_at
                       ) VALUES (?, 'started', 'video', ?, 'Available nil count video', ?,
                                 json(?), ?, 'invalid-video-workout-type', ?, 'six_count',
                                 480, 'logged', ?, ?)
                       """,
                       [
                         facts.user_id,
                         facts.nil_count_video_id,
                         workout_type_snapshot,
                         video_snapshot,
                         video_hash,
                         now,
                         now,
                         now
                       ]
                     )
                   end
    end

    for {workout_type_snapshot, burpee_type} <- [
          {"navy_seal", "six_count"},
          {"six_count", "navy_seal"}
        ] do
      assert_raise Exqlite.Error,
                   ~r/workout_sessions_source_snapshot_check|workout_sessions_live_video_snapshot_check/,
                   fn ->
                     repo.query!(
                       """
                       INSERT INTO workout_sessions (
                         user_id, state, source_kind, workout_video_id,
                         display_name_snapshot, workout_type_snapshot, video_snapshot,
                         content_hash, client_session_id, started_at, burpee_type,
                         duration_sec_planned, capture_mode, inserted_at, updated_at
                       ) VALUES (?, 'started', 'video', ?, 'Available nil count video', ?,
                                 json(?), ?, 'mismatched-video-workout-type', ?, ?,
                                 480, 'logged', ?, ?)
                       """,
                       [
                         facts.user_id,
                         facts.nil_count_video_id,
                         workout_type_snapshot,
                         video_snapshot,
                         video_hash,
                         now,
                         burpee_type,
                         now,
                         now
                       ]
                     )
                   end
    end

    assert_raise Exqlite.Error, ~r/workout_sessions_source_snapshot_check/, fn ->
      repo.query!(
        """
        INSERT INTO workout_sessions (
          user_id, state, source_kind, workout_video_id, workout_type_snapshot,
          video_snapshot, content_hash, client_session_id, started_at,
          burpee_type, capture_mode, inserted_at, updated_at
        ) VALUES (?, 'started', 'video', ?, 'six_count', json(?), ?,
                  'missing-video-display', ?, 'six_count', 'logged', ?, ?)
        """,
        [facts.user_id, facts.nil_count_video_id, video_snapshot, video_hash, now, now, now]
      )
    end

    assert_raise Exqlite.Error, ~r/workout_sessions_state_transition_check/, fn ->
      repo.query!("UPDATE workout_sessions SET state = 'started' WHERE id = ?", [
        facts.structured_session_id
      ])
    end

    assert_raise Exqlite.Error, ~r/workout_sessions_exact_once_completion_check/, fn ->
      repo.query!("UPDATE workout_sessions SET display_name_snapshot = 'changed' WHERE id = ?", [
        facts.structured_session_id
      ])
    end

    assert_raise Exqlite.Error, ~r/workout_sessions_exact_once_completion_check/, fn ->
      repo.query!(
        "UPDATE workout_sessions SET burpee_count_actual = burpee_count_actual + 1 WHERE id = ?",
        [facts.structured_session_id]
      )
    end

    for {field, value} <- [
          {"note_post", "'mutated'"},
          {"preference_feedback", "'avoid'"},
          {"rate_avg_rolling_3", "99.0"}
        ] do
      assert_raise Exqlite.Error, ~r/workout_sessions_exact_once_completion_check/, fn ->
        repo.query!("UPDATE workout_sessions SET #{field} = #{value} WHERE id = ?", [
          facts.structured_session_id
        ])
      end
    end

    :ok
  end

  defp assert_valid_row_shapes!(repo, facts, fallback_id, now) do
    [[fallback_name, fallback_type, fallback_program, fallback_hash]] =
      repo.query!(
        """
        SELECT name, burpee_type, program_json, content_hash
        FROM workout_plans
        WHERE id = ?
        """,
        [fallback_id]
      ).rows

    plan_session_id =
      insert_id(
        repo,
        """
        INSERT INTO workout_sessions (
          user_id, state, source_kind, plan_id, display_name_snapshot,
          workout_type_snapshot, program_snapshot, content_hash,
          client_session_id, started_at, burpee_type, burpee_count_planned,
          duration_sec_planned, capture_mode, inserted_at, updated_at
        ) VALUES (?, 'started', 'plan', ?, ?, ?, json(?), ?,
                  'matrix-plan', ?, ?, 10, 120, 'logged', ?, ?)
        """,
        [
          facts.user_id,
          fallback_id,
          fallback_name,
          fallback_type,
          fallback_program,
          fallback_hash,
          now,
          fallback_type,
          now,
          now
        ]
      )

    for {field, value} <- [
          {"burpee_type", "'navy_seal'"},
          {"burpee_count_planned", "11"},
          {"duration_sec_planned", "121"}
        ] do
      assert_raise Exqlite.Error, ~r/workout_sessions_identity_snapshot_immutable_check/, fn ->
        repo.query!("UPDATE workout_sessions SET #{field} = #{value} WHERE id = ?", [
          plan_session_id
        ])
      end
    end

    assert_raise Exqlite.Error, ~r/workout_sessions_identity_snapshot_immutable_check/, fn ->
      repo.query!(
        """
        UPDATE workout_sessions
        SET state = 'completed', burpee_type = 'navy_seal',
            burpee_count_planned = 11, duration_sec_planned = 121,
            burpee_count_actual = 10, duration_sec_actual = 120,
            completed_at = ?, updated_at = ?
        WHERE id = ?
        """,
        [now, now, plan_session_id]
      )
    end

    repo.query!(
      """
      UPDATE workout_sessions
      SET state = 'completed', burpee_count_actual = 10,
          duration_sec_actual = 120, completed_at = ?, updated_at = ?
      WHERE id = ?
      """,
      [now, now, plan_session_id]
    )

    assert repo.query!("SELECT state, source_kind FROM workout_sessions WHERE id = ?", [
             plan_session_id
           ]).rows == [["completed", "plan"]]

    [[video_snapshot, video_hash]] =
      repo.query!(
        """
        SELECT video_snapshot, content_hash
        FROM workout_sessions
        WHERE id = ?
        """,
        [facts.nil_count_video_session_id]
      ).rows

    video_session_id =
      insert_id(
        repo,
        """
        INSERT INTO workout_sessions (
          user_id, state, source_kind, workout_video_id, display_name_snapshot,
          workout_type_snapshot, video_snapshot, content_hash,
          client_session_id, started_at, burpee_type, burpee_count_planned,
          duration_sec_planned, capture_mode, inserted_at, updated_at
        ) VALUES (?, 'started', 'video', ?, 'Available nil count video',
                  'six_count', json(?), ?, 'matrix-video', ?, 'six_count',
                  NULL, 480, 'logged', ?, ?)
        """,
        [facts.user_id, facts.nil_count_video_id, video_snapshot, video_hash, now, now, now]
      )

    for {field, value} <- [
          {"burpee_type", "'navy_seal'"},
          {"burpee_count_planned", "17"},
          {"duration_sec_planned", "481"}
        ] do
      assert_raise Exqlite.Error, ~r/workout_sessions_identity_snapshot_immutable_check/, fn ->
        repo.query!("UPDATE workout_sessions SET #{field} = #{value} WHERE id = ?", [
          video_session_id
        ])
      end
    end

    repo.query!(
      """
      UPDATE workout_sessions
      SET state = 'completed', burpee_count_actual = 17,
          duration_sec_actual = 490, completed_at = ?, updated_at = ?
      WHERE id = ?
      """,
      [now, now, video_session_id]
    )

    assert repo.query!("SELECT state, source_kind FROM workout_sessions WHERE id = ?", [
             video_session_id
           ]).rows == [["completed", "video"]]

    manual_session_id =
      insert_id(
        repo,
        """
        INSERT INTO workout_sessions (
          user_id, state, source_kind, completed_at, burpee_type,
          burpee_count_actual, duration_sec_actual, capture_mode,
          inserted_at, updated_at
        ) VALUES (?, 'completed', 'manual', ?, 'six_count', 5, 60,
                  'logged', ?, ?)
        """,
        [facts.user_id, now, now, now]
      )

    draft_id =
      insert_id(
        repo,
        """
        INSERT INTO workout_plans (
          user_id, name, origin, state, definition_json, program_json,
          content_hash, burpee_type, target_reps, target_duration_sec,
          inserted_at, updated_at
        ) VALUES (?, 'Draft matrix', 'user', 'draft', json(?), json(?),
                  'draft-matrix-hash', 'six_count', 10, 120, ?, ?)
        """,
        [
          facts.user_id,
          Jason.encode!(DeletionFirstFallback.definition_json()),
          fallback_program,
          now,
          now
        ]
      )

    recommendation_id =
      insert_id(
        repo,
        """
        INSERT INTO coach_recommendations (
          user_id, slot_key, slot_date, selected_workout_plan_id,
          pending_draft_id, rationale, inserted_at, updated_at
        ) VALUES (?, 'valid-matrix', '2026-08-29', ?, ?, 'matrix', ?, ?)
        """,
        [facts.user_id, fallback_id, draft_id, now, now]
      )

    assert_raise Exqlite.Error, ~r/workout_plans_pending_draft_check/, fn ->
      repo.query!(
        "UPDATE workout_plans SET state = 'published', published_at = ? WHERE id = ?",
        [now, draft_id]
      )
    end

    other_user_id =
      insert_id(
        repo,
        """
        INSERT INTO users
          (username, password_hash, timezone, timezone_provisioned, inserted_at, updated_at)
        VALUES ('pending-owner', 'hash', 'Etc/UTC', 1, ?, ?)
        """,
        [now, now]
      )

    assert_raise Exqlite.Error, ~r/workout_plans_pending_draft_check/, fn ->
      repo.query!("UPDATE workout_plans SET user_id = ? WHERE id = ?", [other_user_id, draft_id])
    end

    repo.query!("DELETE FROM coach_recommendations WHERE id = ?", [recommendation_id])
    repo.query!("DELETE FROM workout_plans WHERE id = ?", [draft_id])
    repo.query!("DELETE FROM users WHERE id = ?", [other_user_id])

    repo.query!("DELETE FROM workout_sessions WHERE id IN (?, ?, ?)", [
      plan_session_id,
      video_session_id,
      manual_session_id
    ])

    :ok
  end

  defp assert_non_unique_content_hash_index!(repo, facts) do
    hash_index_rows =
      repo.query!("PRAGMA index_list('workout_plans')").rows
      |> Enum.filter(fn [_sequence, name, _unique, _origin, _partial] ->
        name == "workout_plans_content_hash_index"
      end)

    assert [[_sequence, "workout_plans_content_hash_index", 0, _origin, 0]] = hash_index_rows

    now = "2026-08-31T01:00:00Z"
    duplicate_hash = "shared-fingerprint-not-identity"

    for name <- ["Shared fingerprint A", "Shared fingerprint B"] do
      repo.query!(
        """
        INSERT INTO workout_plans (
          user_id, name, origin, state, definition_json, program_json,
          content_hash, burpee_type, target_reps, target_duration_sec,
          inserted_at, updated_at
        ) VALUES (?, ?, 'user', 'draft', json('{}'), json('{}'), ?,
                  'six_count', 10, 120, ?, ?)
        """,
        [facts.user_id, name, duplicate_hash, now, now]
      )
    end

    assert repo.query!("SELECT COUNT(*) FROM workout_plans WHERE content_hash = ?", [
             duplicate_hash
           ]).rows == [[2]]

    repo.query!("DELETE FROM workout_plans WHERE content_hash = ?", [duplicate_hash])
    :ok
  end

  defp assert_terminal_retry_rejected!(repo) do
    migration_version = migration_version(hd(Path.wildcard(@migration_glob)))
    migrations = isolated_migrations(@migration_dir)
    repo.query!("DELETE FROM schema_migrations WHERE version = ?", [migration_version])

    assert_raise RuntimeError,
                 ~r/unsupported workout-library migration state|target schema validation failed|database integrity check failed|invalid pending draft facts|invalid live plan snapshot facts|invalid video snapshot hash|invalid sqlite_sequence/,
                 fn ->
                   Ecto.Migrator.run(repo, migrations, :up, to: migration_version)
                 end

    assert repo.query!("SELECT version FROM schema_migrations WHERE version = ?", [
             migration_version
           ]).rows == []

    assert repo.query!("PRAGMA foreign_keys").rows == [[1]]
    :ok
  end

  defp with_final_migration_repo(fun) do
    with_isolated_repo(fn repo ->
      facts = seed_raw_rows(repo)
      migration_version = migration_version(hd(Path.wildcard(@migration_glob)))
      migrations = isolated_migrations(@migration_dir)
      _ = Ecto.Migrator.run(repo, migrations, :up, to: migration_version)
      fun.(repo, migrations, migration_version, facts)
    end)
  end

  defp seed_raw_rows(repo) do
    repo.checkout(
      fn -> fixture_seed_raw_rows(repo) end,
      timeout: :infinity
    )
  end

  defp insert_final_video!(repo, snapshot) do
    now = "2026-08-30T00:00:00Z"

    insert_id(
      repo,
      """
      INSERT INTO workout_videos (
        name, filename, burpee_type, duration_sec, burpee_count,
        available, format, inserted_at
      ) VALUES (?, ?, ?, ?, ?, 1, ?, ?)
      """,
      [
        snapshot["name"],
        snapshot["filename"],
        snapshot["type"],
        snapshot["duration"],
        snapshot["count"],
        snapshot["format"],
        now
      ]
    )
  end

  defp terminal_target_snapshot(repo) do
    tables =
      ~w[workout_plans coach_recommendations workout_sessions pose_capture_runs pose_trace_chunks workout_videos]

    %{
      schema:
        repo.query!("""
        SELECT type, name, tbl_name, sql
        FROM sqlite_master
        WHERE name <> 'schema_migrations'
          AND tbl_name <> 'schema_migrations'
          AND name NOT LIKE 'sqlite_autoindex_schema_migrations%'
        ORDER BY type, name
        """).rows,
      data:
        Enum.map(tables, fn table ->
          {table, repo.query!("SELECT * FROM #{table} ORDER BY id").rows}
        end),
      sequences: repo.query!("SELECT name, seq FROM sqlite_sequence ORDER BY name").rows
    }
  end

  defp predecessor_snapshot(repo) do
    tables =
      repo.query!("""
      SELECT name
      FROM sqlite_master
      WHERE type = 'table' AND name <> 'sqlite_sequence'
      ORDER BY name
      """).rows
      |> List.flatten()

    %{
      schema:
        repo.query!("""
        SELECT type, name, tbl_name, sql
        FROM sqlite_master
        ORDER BY type, name
        """).rows,
      data:
        Enum.map(tables, fn table ->
          quoted = String.replace(table, "\"", "\"\"")
          {table, repo.query!(~s(SELECT * FROM "#{quoted}" ORDER BY rowid)).rows}
        end),
      sequences: repo.query!("SELECT name, seq FROM sqlite_sequence ORDER BY name").rows
    }
  end

  defp helper_tables(repo) do
    repo.query!(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'deletion_first_%' ORDER BY name"
    ).rows
  end

  defp insert_id(repo, sql, params) do
    repo.checkout(
      fn ->
        repo.query!(sql, params)
        repo.query!("SELECT last_insert_rowid()").rows |> hd() |> hd()
      end,
      timeout: :infinity
    )
  end

  defp schema_object_sql(repo, type, table) do
    repo.query!(
      """
      SELECT name, sql FROM sqlite_master
      WHERE type = ? AND tbl_name = ?
      ORDER BY name
      """,
      [type, table]
    ).rows
    |> Enum.map(fn [name, sql] -> {name, sql} end)
  end

  defp table_sql(repo, table) do
    [[sql]] =
      repo.query!("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table]).rows

    sql
  end

  defp with_isolated_repo(fun) do
    database_path =
      Path.join(
        System.tmp_dir!(),
        "deletion-first-migration-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}.db"
      )

    try do
      configure_isolated_repo(database_path, 1)

      assert {:ok, _result, _apps} =
               Ecto.Migrator.with_repo(
                 IsolatedMigrationRepo,
                 fn repo ->
                   migrations = isolated_migrations(@migration_dir)
                   Ecto.Migrator.run(repo, migrations, :up, to: @legacy_version)
                 end,
                 mode: :temporary,
                 pool_size: 1
               )

      configure_isolated_repo(database_path, 5)

      assert {:ok, _result, _apps} =
               Ecto.Migrator.with_repo(
                 IsolatedMigrationRepo,
                 fn repo -> fun.(repo) end,
                 mode: :temporary,
                 pool_size: 5
               )
    after
      Application.delete_env(:burpee_trainer, IsolatedMigrationRepo)
      File.rm(database_path)
      File.rm("#{database_path}-shm")
      File.rm("#{database_path}-wal")
    end
  end

  defp configure_isolated_repo(database_path, pool_size) do
    Application.put_env(:burpee_trainer, IsolatedMigrationRepo,
      database: database_path,
      pool_size: pool_size,
      journal_mode: :wal,
      busy_timeout: 10_000,
      stacktrace: true,
      show_sensitive_data_on_connection_error: true
    )
  end

  defp migration_version(file) do
    file |> Path.basename() |> String.split("_", parts: 2) |> hd() |> String.to_integer()
  end

  defp isolated_migrations(path) do
    path
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn migration_path ->
      version = migration_version(migration_path)
      modules = migration_modules(migration_path)

      unless Enum.all?(modules, &Code.ensure_loaded?/1), do: Code.require_file(migration_path)
      Enum.map(modules, &{version, &1})
    end)
  end

  defp migration_modules(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> then(fn ast ->
      {_ast, modules} =
        Macro.prewalk(ast, [], fn
          {:defmodule, _, [{:__aliases__, _, parts}, _]} = node, acc ->
            {node, [Module.concat(parts) | acc]}

          node, acc ->
            {node, acc}
        end)

      Enum.reverse(modules)
    end)
  end

  @completed_at "2026-08-27T10:00:00Z"
  @older_at "2026-08-26T09:00:00Z"
  @session_columns [
    :user_id,
    :plan_id,
    :execution_program_id,
    :goal_id,
    :workout_video_id,
    :client_session_id,
    :burpee_type,
    :burpee_count_planned,
    :duration_sec_planned,
    :burpee_count_actual,
    :duration_sec_actual,
    :note_pre,
    :note_post,
    :mood,
    :tags,
    :capture_mode,
    :cadence_ms,
    :target_pace_sec,
    :pace_consistency,
    :context_low_energy,
    :context_high_energy,
    :context_heat_affected,
    :primary_limiter,
    :preference_feedback,
    :prescribed_sets_completed,
    :reps_delta,
    :shortened,
    :recovery_delta_sec,
    :pace_delta_sec,
    :cadence_decline,
    :style_name,
    :rate_per_min_actual,
    :days_since_last,
    :rate_delta,
    :rate_avg_rolling_3,
    :time_of_day_bucket,
    :inserted_at,
    :updated_at
  ]

  defp fixture_seed_raw_rows(repo) do
    session_triggers =
      repo.query!(
        "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'workout_sessions'"
      ).rows

    Enum.each(session_triggers, fn [name, _sql] ->
      quoted_name = String.replace(name, "\"", "\"\"")
      repo.query!(~s(DROP TRIGGER "#{quoted_name}"))
    end)

    suffix = System.unique_integer([:positive, :monotonic])

    user_id =
      fixture_insert_id(
        repo,
        """
        INSERT INTO users
          (username, password_hash, timezone, timezone_provisioned, inserted_at, updated_at)
        VALUES (?, 'fixture-hash', 'Etc/UTC', 1, ?, ?)
        """,
        ["deletion_first_#{suffix}", @older_at, @older_at]
      )

    goal_id =
      fixture_insert_id(
        repo,
        """
        INSERT INTO goals
          (user_id, burpee_type, burpee_count_target, duration_sec_target,
           date_target, burpee_count_baseline, duration_sec_baseline, date_baseline,
           status, inserted_at, updated_at)
        VALUES (?, 'six_count', 60, 300, '2026-09-30', 30, 240, '2026-08-01',
                'active', ?, ?)
        """,
        [user_id, @older_at, @older_at]
      )

    existing_program = insert_program(repo, "existing-#{suffix}", 30, 300)
    missing_program = insert_program(repo, "missing-#{suffix}", 20, 240)
    abandoned_program = insert_program(repo, "abandoned-#{suffix}", 12, 180)
    deleted_plan_program = insert_program(repo, "deleted-plan-#{suffix}", 15, 210)

    structured_plan_id =
      insert_plan(repo, user_id, existing_program.id, "Named structured history", 30, 5)

    missing_program_plan_id =
      insert_plan(repo, user_id, missing_program.id, "Missing program history", 20, 4)

    abandoned_plan_id =
      insert_plan(repo, user_id, abandoned_program.id, "Abandoned configurable workout", 12, 3)

    deleted_source_plan_id =
      insert_plan(repo, user_id, deleted_plan_program.id, "Deleted source plan", 15, 4)

    deleted_high_water_plan_id =
      insert_plan(repo, user_id, existing_program.id, "Deleted sequence high-water", 1, 1)

    repo.query!("DELETE FROM workout_plans WHERE id = ?", [deleted_high_water_plan_id])
    workout_plans_sequence_before = sqlite_sequence!(repo, "workout_plans")

    prescribed_video_id =
      insert_video(repo, "Prescribed count video", "prescribed-#{suffix}.mp4", 600, 40)

    nil_count_video_id =
      insert_video(repo, "Available nil count video", "nil-count-#{suffix}.mp4", 480, nil)

    structured_session_id =
      insert_session(repo, %{
        user_id: user_id,
        plan_id: structured_plan_id,
        execution_program_id: existing_program.id,
        goal_id: goal_id,
        client_session_id: "structured-#{suffix}",
        burpee_count_planned: 30,
        duration_sec_planned: 300,
        burpee_count_actual: 28,
        duration_sec_actual: 310,
        note_pre: "Steady start",
        note_post: "Strong finish",
        mood: 1,
        tags: "history,tracked",
        capture_mode: "tracked",
        cadence_ms: "[10000,10500,11000]",
        target_pace_sec: 10.0,
        pace_consistency: 0.91,
        context_low_energy: 1,
        context_heat_affected: 1,
        primary_limiter: "breathing",
        preference_feedback: "choose_again",
        prescribed_sets_completed: 3,
        reps_delta: -2,
        shortened: 0,
        recovery_delta_sec: 5,
        pace_delta_sec: 0.5,
        cadence_decline: 0.1,
        style_name: "steady",
        rate_per_min_actual: 5.42,
        days_since_last: 3,
        rate_delta: 0.42,
        rate_avg_rolling_3: 5.1,
        time_of_day_bucket: "morning",
        inserted_at: @completed_at
      })

    missing_program_session_id =
      insert_session(repo, %{
        user_id: user_id,
        plan_id: missing_program_plan_id,
        execution_program_id: missing_program.id,
        client_session_id: "missing-program-#{suffix}",
        burpee_count_planned: 20,
        duration_sec_planned: 240,
        burpee_count_actual: 19,
        duration_sec_actual: 245,
        note_pre: "Legacy plan",
        note_post: "Program later removed",
        mood: 0,
        tags: "history",
        capture_mode: "timed",
        context_high_energy: 1,
        primary_limiter: "whole_body",
        preference_feedback: "avoid",
        prescribed_sets_completed: 2,
        reps_delta: -1,
        shortened: 0,
        style_name: "legacy",
        rate_per_min_actual: 4.65,
        days_since_last: 1,
        rate_delta: -0.2,
        rate_avg_rolling_3: 4.9,
        time_of_day_bucket: "afternoon",
        inserted_at: "2026-08-27T09:00:00Z"
      })

    prescribed_video_session_id =
      insert_session(repo, %{
        user_id: user_id,
        workout_video_id: prescribed_video_id,
        client_session_id: "prescribed-video-#{suffix}",
        burpee_count_planned: 40,
        duration_sec_planned: 600,
        burpee_count_actual: 42,
        duration_sec_actual: 610,
        note_pre: "Follow along",
        note_post: "Two extra reps",
        mood: 1,
        tags: "video",
        capture_mode: "logged",
        primary_limiter: "upper_body",
        preference_feedback: "choose_again",
        style_name: "video",
        rate_per_min_actual: 4.13,
        days_since_last: 2,
        rate_delta: 0.13,
        rate_avg_rolling_3: 4.0,
        time_of_day_bucket: "evening",
        inserted_at: "2026-08-27T08:00:00Z"
      })

    shared_prescribed_video_session_id =
      insert_session(repo, %{
        user_id: user_id,
        workout_video_id: prescribed_video_id,
        client_session_id: "shared-prescribed-video-#{suffix}",
        burpee_count_planned: 40,
        duration_sec_planned: 600,
        burpee_count_actual: 39,
        duration_sec_actual: 605,
        note_post: "Shared video history",
        capture_mode: "logged",
        inserted_at: "2026-08-27T07:30:00Z"
      })

    nil_count_video_session_id =
      insert_session(repo, %{
        user_id: user_id,
        workout_video_id: nil_count_video_id,
        client_session_id: "nil-count-video-#{suffix}",
        burpee_count_planned: nil,
        duration_sec_planned: 480,
        burpee_count_actual: 17,
        duration_sec_actual: 490,
        note_pre: "No catalog count",
        note_post: "Confirmed actual retained",
        mood: -1,
        tags: "video,nil-count",
        capture_mode: "timed",
        context_heat_affected: 1,
        primary_limiter: "legs",
        preference_feedback: "avoid",
        style_name: "video",
        rate_per_min_actual: 2.08,
        days_since_last: 4,
        rate_delta: -0.5,
        rate_avg_rolling_3: 3.2,
        time_of_day_bucket: "night",
        inserted_at: "2026-08-27T07:00:00Z"
      })

    deleted_plan_session_id =
      insert_session(repo, %{
        user_id: user_id,
        plan_id: deleted_source_plan_id,
        execution_program_id: deleted_plan_program.id,
        client_session_id: "deleted-plan-#{suffix}",
        burpee_count_planned: 15,
        duration_sec_planned: 210,
        burpee_count_actual: 14,
        duration_sec_actual: 215,
        note_post: "Plan deleted before migration",
        capture_mode: "logged",
        inserted_at: "2026-08-27T06:30:00Z"
      })

    repo.query!("DELETE FROM workout_plans WHERE id = ?", [deleted_source_plan_id])

    incomplete_session_id =
      insert_session(repo, %{
        user_id: user_id,
        plan_id: abandoned_plan_id,
        execution_program_id: abandoned_program.id,
        client_session_id: "abandoned-#{suffix}",
        burpee_count_planned: 12,
        duration_sec_planned: 180,
        burpee_count_actual: nil,
        duration_sec_actual: nil,
        note_pre: "Never completed",
        capture_mode: "tracked",
        inserted_at: "2026-08-27T06:00:00Z"
      })

    pose_incomplete_session_id =
      insert_session(repo, %{
        user_id: user_id,
        plan_id: abandoned_plan_id,
        execution_program_id: abandoned_program.id,
        client_session_id: "pose-incomplete-#{suffix}",
        burpee_count_planned: 12,
        duration_sec_planned: 180,
        burpee_count_actual: nil,
        duration_sec_actual: nil,
        note_pre: "Completed evidence but incomplete session",
        capture_mode: "tracked",
        inserted_at: "2026-08-27T05:30:00Z"
      })

    attached_pose_run_id =
      insert_pose_run(repo, user_id, structured_plan_id, structured_session_id, "completed")

    unattached_pose_run_id =
      insert_pose_run(repo, user_id, missing_program_plan_id, nil, "completed")

    completed_run_on_incomplete_session_id =
      insert_pose_run(repo, user_id, abandoned_plan_id, pose_incomplete_session_id, "completed")

    active_pose_run_id =
      insert_pose_run(repo, user_id, abandoned_plan_id, incomplete_session_id, "active")

    attached_pose_chunk_id = insert_pose_chunk(repo, attached_pose_run_id, 0, "main")
    unattached_pose_chunk_id = insert_pose_chunk(repo, unattached_pose_run_id, 0, "warmup")

    completed_chunk_on_incomplete_session_id =
      insert_pose_chunk(repo, completed_run_on_incomplete_session_id, 0, "main")

    active_pose_chunk_id = insert_pose_chunk(repo, active_pose_run_id, 0, "main")

    repo.query!("DELETE FROM execution_programs WHERE id = ?", [missing_program.id])

    facts = %{
      user_id: user_id,
      goal_id: goal_id,
      existing_program_id: existing_program.id,
      structured_program: existing_program.program,
      structured_program_hash: existing_program.content_hash,
      missing_program_id: missing_program.id,
      abandoned_program_id: abandoned_program.id,
      deleted_plan_program_id: deleted_plan_program.id,
      deleted_plan_program: deleted_plan_program.program,
      deleted_plan_program_hash: deleted_plan_program.content_hash,
      legacy_plan_ids: [structured_plan_id, missing_program_plan_id, abandoned_plan_id],
      deleted_source_plan_id: deleted_source_plan_id,
      deleted_high_water_plan_id: deleted_high_water_plan_id,
      workout_plans_sequence_before: workout_plans_sequence_before,
      structured_plan_id: structured_plan_id,
      missing_program_plan_id: missing_program_plan_id,
      abandoned_plan_id: abandoned_plan_id,
      prescribed_video_id: prescribed_video_id,
      nil_count_video_id: nil_count_video_id,
      completed_session_ids: [
        structured_session_id,
        missing_program_session_id,
        prescribed_video_session_id,
        shared_prescribed_video_session_id,
        nil_count_video_session_id,
        deleted_plan_session_id
      ],
      structured_session_id: structured_session_id,
      missing_program_session_id: missing_program_session_id,
      prescribed_video_session_id: prescribed_video_session_id,
      shared_prescribed_video_session_id: shared_prescribed_video_session_id,
      nil_count_video_session_id: nil_count_video_session_id,
      deleted_plan_session_id: deleted_plan_session_id,
      incomplete_session_id: incomplete_session_id,
      pose_incomplete_session_id: pose_incomplete_session_id,
      completed_pose_run_ids: [
        attached_pose_run_id,
        unattached_pose_run_id,
        completed_run_on_incomplete_session_id
      ],
      attached_pose_run_id: attached_pose_run_id,
      unattached_pose_run_id: unattached_pose_run_id,
      completed_run_on_incomplete_session_id: completed_run_on_incomplete_session_id,
      active_pose_run_id: active_pose_run_id,
      completed_pose_chunk_ids: [
        attached_pose_chunk_id,
        unattached_pose_chunk_id,
        completed_chunk_on_incomplete_session_id
      ],
      attached_pose_chunk_id: attached_pose_chunk_id,
      unattached_pose_chunk_id: unattached_pose_chunk_id,
      completed_chunk_on_incomplete_session_id: completed_chunk_on_incomplete_session_id,
      active_pose_chunk_id: active_pose_chunk_id
    }

    Enum.each(session_triggers, fn [_name, sql] -> repo.query!(sql) end)
    facts
  end

  defp normalized_facts(repo) do
    %{
      videos: normalized_rows(video_result(repo)),
      sessions: normalized_rows(session_result(repo)),
      pose_runs: normalized_rows(pose_run_result(repo)),
      pose_chunks: normalized_rows(pose_chunk_result(repo))
    }
  end

  defp assert_seed_baseline!(repo, facts) do
    normalized = normalized_facts(repo)

    assert Enum.map(normalized.sessions, & &1["id"]) == Enum.sort(facts.completed_session_ids)
    assert Enum.map(normalized.pose_runs, & &1["id"]) == Enum.sort(facts.completed_pose_run_ids)

    assert Enum.map(normalized.pose_chunks, & &1["id"]) ==
             Enum.sort(facts.completed_pose_chunk_ids)

    assert length(normalized.videos) == 2
    assert facts.deleted_high_water_plan_id > Enum.max(facts.legacy_plan_ids)
    assert facts.workout_plans_sequence_before == facts.deleted_high_water_plan_id
    assert sqlite_sequence!(repo, "workout_plans") == facts.workout_plans_sequence_before

    assert repo.query!("SELECT id FROM workout_plans WHERE id = ?", [
             facts.deleted_high_water_plan_id
           ]).rows == []

    nil_video = row!(normalized.videos, facts.nil_count_video_id)
    assert nil_video["burpee_count"] == nil
    assert nil_video["available"] == 1

    nil_count_session = row!(normalized.sessions, facts.nil_count_video_session_id)
    assert nil_count_session["burpee_count_planned"] == nil
    assert nil_count_session["burpee_count_actual"] == 17

    assert repo.query!("SELECT execution_program_id FROM workout_sessions WHERE id = ?", [
             facts.missing_program_session_id
           ]).rows == [[nil]]

    assert repo.query!(
             "SELECT plan_id, execution_program_id FROM workout_sessions WHERE id = ?",
             [
               facts.deleted_plan_session_id
             ]
           ).rows == [[nil, facts.deleted_plan_program_id]]

    assert repo.query!("SELECT id FROM workout_sessions WHERE id IN (?, ?) ORDER BY id", [
             facts.incomplete_session_id,
             facts.pose_incomplete_session_id
           ]).rows ==
             [[facts.incomplete_session_id], [facts.pose_incomplete_session_id]]

    assert repo.query!("SELECT id FROM pose_capture_runs WHERE id = ? AND status = 'active'", [
             facts.active_pose_run_id
           ]).rows == [[facts.active_pose_run_id]]

    limiters = MapSet.new(normalized.sessions, & &1["primary_limiter"])
    assert MapSet.subset?(MapSet.new(~w[breathing whole_body upper_body legs]), limiters)

    preferences = MapSet.new(normalized.sessions, & &1["preference_feedback"])
    assert MapSet.subset?(MapSet.new(~w[choose_again avoid]), preferences)

    structured = row!(normalized.sessions, facts.structured_session_id)
    assert structured["goal_id"] == facts.goal_id
    assert structured["capture_mode"] == "tracked"
    assert structured["cadence_ms"] == "[10000,10500,11000]"
    assert structured["style_name"] == "steady"
    assert structured["rate_per_min_actual"] == 5.42
    assert structured["days_since_last"] == 3
    assert structured["rate_delta"] == 0.42
    assert structured["rate_avg_rolling_3"] == 5.1
    assert structured["time_of_day_bucket"] == "morning"
    :ok
  end

  defp assert_post_migration!(repo, before, facts) do
    after_facts = normalized_facts(repo)

    expected_pose_runs =
      Enum.map(before.pose_runs, fn row ->
        if row["id"] == facts.completed_run_on_incomplete_session_id do
          Map.put(row, "workout_session_id", nil)
        else
          row
        end
      end)

    assert after_facts == %{before | pose_runs: expected_pose_runs}

    assert repo.query!("SELECT id FROM users WHERE id = ?", [facts.user_id]).rows == [
             [facts.user_id]
           ]

    attached_run = row!(after_facts.pose_runs, facts.attached_pose_run_id)
    unattached_run = row!(after_facts.pose_runs, facts.unattached_pose_run_id)

    completed_run_on_incomplete =
      row!(after_facts.pose_runs, facts.completed_run_on_incomplete_session_id)

    assert attached_run["workout_session_id"] == facts.structured_session_id
    assert unattached_run["workout_session_id"] == nil
    assert completed_run_on_incomplete["workout_session_id"] == nil

    assert Enum.map(after_facts.pose_chunks, & &1["id"]) ==
             Enum.sort(facts.completed_pose_chunk_ids)

    final_sessions =
      repo.query!("""
      SELECT id, state, source_kind, plan_id, workout_video_id,
             display_name_snapshot, workout_type_snapshot,
             program_snapshot, video_snapshot, content_hash
      FROM workout_sessions
      ORDER BY id
      """)
      |> normalized_rows()

    assert Enum.map(final_sessions, & &1["id"]) == Enum.sort(facts.completed_session_ids)

    structured = row!(final_sessions, facts.structured_session_id)
    assert structured["state"] == "completed"
    assert structured["source_kind"] == "plan"
    assert structured["plan_id"] == nil
    assert structured["display_name_snapshot"] == "Named structured history"
    assert structured["workout_type_snapshot"] == "six_count"
    assert Jason.decode!(structured["program_snapshot"]) == facts.structured_program
    assert structured["content_hash"] == facts.structured_program_hash
    assert structured["video_snapshot"] == nil

    deleted_plan = row!(final_sessions, facts.deleted_plan_session_id)
    assert deleted_plan["state"] == "completed"
    assert deleted_plan["source_kind"] == "plan"
    assert deleted_plan["plan_id"] == nil
    assert deleted_plan["display_name_snapshot"] == "Historical six count workout"
    assert Jason.decode!(deleted_plan["program_snapshot"]) == facts.deleted_plan_program
    assert deleted_plan["content_hash"] == facts.deleted_plan_program_hash

    missing = row!(final_sessions, facts.missing_program_session_id)
    assert missing["state"] == "completed"
    assert missing["source_kind"] == "plan"
    assert missing["plan_id"] == nil
    assert missing["display_name_snapshot"] == "Missing program history"
    assert missing["program_snapshot"] == nil
    assert missing["content_hash"] == nil

    prescribed = row!(final_sessions, facts.prescribed_video_session_id)
    assert prescribed["source_kind"] == "video"
    assert prescribed["workout_video_id"] == facts.prescribed_video_id

    assert Jason.decode!(prescribed["video_snapshot"]) == %{
             "name" => "Prescribed count video",
             "filename" => row!(after_facts.videos, facts.prescribed_video_id)["filename"],
             "type" => "six_count",
             "duration" => 600,
             "count" => 40,
             "format" => "follow_along"
           }

    nil_count = row!(final_sessions, facts.nil_count_video_session_id)
    nil_count_preserved = row!(after_facts.sessions, facts.nil_count_video_session_id)
    video_snapshot = Jason.decode!(nil_count["video_snapshot"])
    assert nil_count["source_kind"] == "video"
    assert nil_count["workout_video_id"] == facts.nil_count_video_id

    assert video_snapshot == %{
             "name" => "Available nil count video",
             "filename" => row!(after_facts.videos, facts.nil_count_video_id)["filename"],
             "type" => "six_count",
             "duration" => 480,
             "count" => nil,
             "format" => "follow_along"
           }

    assert video_snapshot["count"] == nil
    assert nil_count_preserved["burpee_count_planned"] == nil
    assert nil_count_preserved["burpee_count_actual"] == 17

    assert repo.query!("SELECT id FROM workout_sessions WHERE id IN (?, ?)", [
             facts.incomplete_session_id,
             facts.pose_incomplete_session_id
           ]).rows == []

    assert repo.query!("SELECT id FROM pose_capture_runs WHERE id = ?", [facts.active_pose_run_id]).rows ==
             []

    assert repo.query!("SELECT id FROM pose_trace_chunks WHERE id = ?", [
             facts.active_pose_chunk_id
           ]).rows ==
             []

    remaining_legacy_plans =
      repo.query!(
        "SELECT id FROM workout_plans WHERE id IN (?,?,?) ORDER BY id",
        facts.legacy_plan_ids
      ).rows

    assert remaining_legacy_plans == []

    assert [[fallback_id, "built_in", "published"]] =
             repo.query!("""
             SELECT id, origin, state
             FROM workout_plans
             WHERE origin = 'built_in' AND state = 'published'
             """).rows

    assert fallback_id > facts.workout_plans_sequence_before

    assert absent_tables(repo) == []
    :ok
  end

  defp insert_program(repo, content_hash, target_reps, target_duration_sec) do
    program = %{
      "events" => [
        %{
          "kind" => "work",
          "reps" => target_reps,
          "sec_per_rep_us" => 10_000_000,
          "sec_per_burpee_us" => 5_000_000
        }
      ],
      "semantics" => %{"pacing_style" => "even"}
    }

    id =
      fixture_insert_id(
        repo,
        """
        INSERT INTO execution_programs
          (content_hash, schema_version, solver_version, burpee_type, target_reps,
           target_duration_sec, event_count, program_json, summary_json, inserted_at, updated_at)
        VALUES (?, 2, 4, 'six_count', ?, ?, 1, json(?), json('{}'), ?, ?)
        """,
        [
          content_hash,
          target_reps,
          target_duration_sec,
          Jason.encode!(program),
          @older_at,
          @older_at
        ]
      )

    %{id: id, program: program, content_hash: content_hash}
  end

  defp insert_plan(repo, user_id, program_id, name, target_reps, duration_min) do
    fixture_insert_id(
      repo,
      """
      INSERT INTO workout_plans
        (user_id, name, burpee_type, style_name, target_duration_min,
         burpee_count_target, sec_per_burpee, pacing_style, fatigue_factor,
         source_json, current_execution_program_id, inserted_at, updated_at)
      VALUES (?, ?, 'six_count', 'steady', ?, ?, 5.0, 'even', 0.0,
              json('{}'), ?, ?, ?)
      """,
      [user_id, name, duration_min, target_reps, program_id, @older_at, @older_at]
    )
  end

  defp insert_video(repo, name, filename, duration_sec, count) do
    fixture_insert_id(
      repo,
      """
      INSERT INTO workout_videos
        (name, filename, burpee_type, duration_sec, burpee_count, available, format, inserted_at)
      VALUES (?, ?, 'six_count', ?, ?, 1, 'follow_along', ?)
      """,
      [name, filename, duration_sec, count, @older_at]
    )
  end

  defp insert_session(repo, overrides) do
    defaults = %{
      user_id: nil,
      plan_id: nil,
      execution_program_id: nil,
      goal_id: nil,
      workout_video_id: nil,
      client_session_id: nil,
      burpee_type: "six_count",
      burpee_count_planned: nil,
      duration_sec_planned: nil,
      burpee_count_actual: nil,
      duration_sec_actual: nil,
      note_pre: nil,
      note_post: nil,
      mood: nil,
      tags: nil,
      capture_mode: "logged",
      cadence_ms: nil,
      target_pace_sec: nil,
      pace_consistency: nil,
      context_low_energy: 0,
      context_high_energy: 0,
      context_heat_affected: 0,
      primary_limiter: nil,
      preference_feedback: nil,
      prescribed_sets_completed: nil,
      reps_delta: nil,
      shortened: nil,
      recovery_delta_sec: nil,
      pace_delta_sec: nil,
      cadence_decline: nil,
      style_name: nil,
      rate_per_min_actual: nil,
      days_since_last: nil,
      rate_delta: nil,
      rate_avg_rolling_3: nil,
      time_of_day_bucket: nil,
      inserted_at: @completed_at,
      updated_at: @completed_at
    }

    attrs = Map.merge(defaults, overrides)
    columns = Enum.join(@session_columns, ", ")
    placeholders = Enum.map_join(@session_columns, ", ", fn _ -> "?" end)
    values = Enum.map(@session_columns, &encode_value(&1, Map.fetch!(attrs, &1)))

    fixture_insert_id(
      repo,
      "INSERT INTO workout_sessions (#{columns}) VALUES (#{placeholders})",
      values
    )
  end

  defp insert_pose_run(repo, user_id, plan_id, session_id, status) do
    completed_at = if status == "completed", do: @completed_at, else: nil

    fixture_insert_id(
      repo,
      """
      INSERT INTO pose_capture_runs
        (user_id, plan_id, workout_session_id, status, capture_version,
         started_at, completed_at, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?)
      """,
      [user_id, plan_id, session_id, status, @older_at, completed_at, @older_at, @completed_at]
    )
  end

  defp insert_pose_chunk(repo, run_id, chunk_index, segment) do
    payload = Jason.encode!(%{"samples" => [%{"elapsed_ms" => 1000, "rep" => chunk_index + 1}]})

    fixture_insert_id(
      repo,
      """
      INSERT INTO pose_trace_chunks
        (pose_capture_run_id, segment, chunk_index, started_at_ms, ended_at_ms,
         sample_count, payload_json, inserted_at, updated_at)
      VALUES (?, ?, ?, 1000, 2000, 1, ?, ?, ?)
      """,
      [run_id, segment, chunk_index, payload, @older_at, @completed_at]
    )
  end

  defp fixture_insert_id(repo, sql, params) do
    repo.query!(sql, params)
    repo.query!("SELECT last_insert_rowid()").rows |> hd() |> hd()
  end

  defp sqlite_sequence!(repo, table) do
    case repo.query!("SELECT seq FROM sqlite_sequence WHERE name = ?", [table]).rows do
      [[sequence]] when is_integer(sequence) -> sequence
      rows -> flunk("missing sqlite_sequence for #{table}: #{inspect(rows)}")
    end
  end

  defp encode_value(_field, value), do: value

  defp video_result(repo) do
    repo.query!("""
    SELECT id, name, filename, burpee_type, duration_sec, burpee_count,
           available, format, inserted_at
    FROM workout_videos
    ORDER BY id
    """)
  end

  defp session_result(repo) do
    repo.query!("""
    SELECT id, user_id, client_session_id, burpee_type,
           burpee_count_planned, duration_sec_planned,
           burpee_count_actual, duration_sec_actual,
           note_pre, note_post, mood, tags, capture_mode,
           cadence_ms, target_pace_sec, pace_consistency,
           context_low_energy, context_high_energy,
           context_heat_affected, primary_limiter,
           preference_feedback, prescribed_sets_completed,
           reps_delta, shortened, recovery_delta_sec,
           pace_delta_sec, cadence_decline,
           style_name, rate_per_min_actual, days_since_last, rate_delta,
           rate_avg_rolling_3, time_of_day_bucket, goal_id,
           inserted_at, updated_at
    FROM workout_sessions
    WHERE burpee_count_actual IS NOT NULL
      AND duration_sec_actual IS NOT NULL
    ORDER BY id
    """)
  end

  defp pose_run_result(repo) do
    repo.query!("""
    SELECT id, user_id, workout_session_id, status, capture_version,
           started_at, completed_at
    FROM pose_capture_runs
    WHERE status = 'completed'
    ORDER BY id
    """)
  end

  defp pose_chunk_result(repo) do
    repo.query!("""
    SELECT ptc.id, ptc.pose_capture_run_id, ptc.segment, ptc.chunk_index,
           ptc.started_at_ms, ptc.ended_at_ms, ptc.sample_count,
           ptc.payload_json
    FROM pose_trace_chunks AS ptc
    JOIN pose_capture_runs AS pcr ON pcr.id = ptc.pose_capture_run_id
    WHERE pcr.status = 'completed'
    ORDER BY ptc.id
    """)
  end

  defp normalized_rows(%{columns: columns, rows: rows}) do
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp row!(rows, id), do: Enum.find(rows, &(&1["id"] == id)) || flunk("missing row #{id}")

  defp absent_tables(repo) do
    obsolete = ~w[
      execution_programs coach_workout_threads coach_messages coach_generation_attempts
      coach_workout_drafts prepared_workouts coach_preparation_events
    ]

    repo.query!("SELECT name FROM sqlite_master WHERE type = 'table'").rows
    |> List.flatten()
    |> Enum.filter(&(&1 in obsolete))
    |> Enum.sort()
  end
end
