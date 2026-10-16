defmodule BurpeeTrainer.SchemaMigrationTest do
  use ExUnit.Case, async: false
  alias BurpeeTrainer.TestSupport.MigrationEquivalence, as: E

  @dir Path.expand("../../priv/repo/migrations", __DIR__)
  @version 20_261_005_000_000
  @path Path.join(@dir, "20261005000000_coach_first_schema.exs")

  setup_all do
    unless Code.ensure_loaded?(BurpeeTrainer.Repo.Migrations.CoachFirstSchema),
      do: Code.require_file(@path)

    source = File.read!(@path)

    variants =
      for {name, mutation} <- [
            {:target_mismatch,
             fn text ->
               String.replace(
                 text,
                 "CREATE INDEX workout_plans_content_hash_index",
                 "CREATE UNIQUE INDEX workout_plans_content_hash_index",
                 global: false
               )
             end},
            {:fk_violation,
             fn text ->
               String.replace(
                 text,
                 "  defp validate_target! do",
                 "  defp validate_target! do\n    repo().query!(\"UPDATE goals SET user_id = 999999\")",
                 global: false
               )
             end},
            {:exception,
             fn text ->
               String.replace(
                 text,
                 "  defp validate_target! do",
                 "  defp validate_target! do\n    raise \"injected migration exception\"",
                 global: false
               )
             end},
            {:owner_exit,
             fn text ->
               String.replace(
                 text,
                 "  defp validate_target! do",
                 "  defp validate_target! do\n    send(Application.fetch_env!(:burpee_trainer, :schema_proof_parent), {:inside_transaction, self()})\n    receive do :finish -> :ok end",
                 global: false
               )
             end},
            {:disable_failure,
             fn text ->
               String.replace(
                 text,
                 "  defp assert_pragma_foreign_keys!(expected) do",
                 "  defp assert_pragma_foreign_keys!(expected) do\n    if expected == 0, do: raise(\"injected FK disable verification failure\")",
                 global: false
               )
             end},
            {:commit_gap,
             fn text ->
               String.replace(
                 text,
                 "      after\n",
                 "        raise \"injected commit/version gap\"\n      after\n",
                 global: false
               )
             end}
          ] do
        mutated = mutation.(source)
        assert mutated != source

        replacement =
          "BurpeeTrainer.TestSupport.SchemaProof.#{Macro.camelize(Atom.to_string(name))}"

        mutated =
          String.replace(mutated, "BurpeeTrainer.Repo.Migrations.CoachFirstSchema", replacement,
            global: false
          )

        [{module, _}] = Code.compile_string(mutated, @path)
        {name, module}
      end

    {:ok, variants: Map.new(variants)}
  end

  test "target mismatch, FK violation, exception and FK-disable failure roll back with FK restored on every pool connection",
       %{variants: variants} do
    task_supervisor = start_supervised!(Task.Supervisor)

    for {variant, error} <- [
          target_mismatch: ~r/target schema validation failed/,
          fk_violation: ~r/foreign key violations/,
          exception: ~r/injected migration exception/,
          disable_failure: ~r/injected FK disable verification failure/
        ] do
      E.with_db(
        fn repo ->
          upstream!(repo)
          E.seed_upstream!(repo)
          before = E.dump(repo)
          versions = repo.query!("SELECT * FROM schema_migrations ORDER BY version").rows

          assert_raise RuntimeError, error, fn ->
            migrate!(repo, Map.fetch!(variants, variant))
          end

          assert E.dump(repo) == before
          assert repo.query!("SELECT * FROM schema_migrations ORDER BY version").rows == versions
          assert repo.query!("SELECT name FROM sqlite_temp_master").rows == []
          assert_pool_restored!(repo, task_supervisor)
        end,
        pool_size: 5
      )
    end
  end

  test "abrupt migration owner exit rolls back the actual transform without sleeps", %{
    variants: variants
  } do
    task_supervisor = start_supervised!(Task.Supervisor)
    Application.put_env(:burpee_trainer, :schema_proof_parent, self())
    on_exit(fn -> Application.delete_env(:burpee_trainer, :schema_proof_parent) end)

    E.with_db(
      fn repo ->
        upstream!(repo)
        E.seed_upstream!(repo)
        before = E.dump(repo)

        {:ok, caller} =
          Task.Supervisor.start_child(task_supervisor, fn ->
            migrate!(repo, variants.owner_exit)
          end)

        caller_ref = Process.monitor(caller)
        assert_receive {:inside_transaction, owner}, 5_000
        owner_ref = Process.monitor(owner)
        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
        assert_receive {:DOWN, ^caller_ref, :process, ^caller, _}, 5_000
        assert E.dump(repo) == before

        assert repo.query!("SELECT version FROM schema_migrations WHERE version = ?", [@version]).rows ==
                 []

        assert_pool_restored!(repo, task_supervisor)
      end,
      pool_size: 5
    )
  end

  test "commit/version gap retries the exact target without changing published plans", %{
    variants: variants
  } do
    E.with_db(fn repo ->
      upstream!(repo)
      E.seed_upstream!(repo)

      assert_raise RuntimeError, ~r/injected commit.version gap/, fn ->
        migrate!(repo, variants.commit_gap)
      end

      assert repo.query!("SELECT version FROM schema_migrations WHERE version = ?", [@version]).rows ==
               []

      before = E.dump(repo)
      migrate!(repo)
      assert E.dump(repo) == before
      assert repo.query!("PRAGMA foreign_keys").rows == [[1]]
    end)
  end

  test "fresh and seeded upstream reach the final schema and restore FK enforcement" do
    for seeded? <- [false, true] do
      E.with_db(fn repo ->
        upstream!(repo)
        facts = if seeded?, do: E.seed_upstream!(repo)
        migrate!(repo)
        assert repo.query!("PRAGMA foreign_keys").rows == [[1]]
        assert repo.query!("PRAGMA foreign_key_check").rows == []
        assert repo.query!("PRAGMA integrity_check").rows == [["ok"]]

        assert repo.query!("SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").rows ==
                 [[61]]

        assert repo.query!(
                 "SELECT COUNT(*) FROM workout_plans WHERE origin = 'built_in' AND state = 'published'"
               ).rows == [[1]]

        [[definition, program, hash, published, inserted, updated]] =
          repo.query!(
            "SELECT definition_json,program_json,content_hash,published_at,inserted_at,updated_at FROM workout_plans WHERE origin='built_in'"
          ).rows

        fallback = BurpeeTrainer.TestFixtures.DeletionFirstFallback
        assert Jason.decode!(definition) == fallback.definition_json()
        assert Jason.decode!(program) == fallback.program_json()
        assert hash == fallback.content_hash()
        assert published == inserted and inserted == updated
        assert {:ok, _, 0} = DateTime.from_iso8601(published)
        assert repo.query!("SELECT name FROM sqlite_temp_master").rows == []
        if seeded?, do: assert_preservation!(repo, facts)
      end)
    end
  end

  test "exact target without version row is a no-op, including sequences and all row data" do
    E.with_db(fn repo ->
      upstream!(repo)
      E.seed_upstream!(repo)
      migrate!(repo)
      # Already-final user published plans are not upstream legacy plan rows.
      repo.query!("""
      INSERT INTO workout_plans (user_id,name,origin,state,definition_json,program_json,content_hash,burpee_type,published_at,inserted_at,updated_at)
      SELECT 1, 'Retained published plan', 'user', 'published', definition_json, program_json, content_hash, burpee_type, published_at, inserted_at, updated_at FROM workout_plans WHERE origin = 'built_in'
      """)

      before = E.dump(repo)
      repo.query!("DELETE FROM schema_migrations WHERE version = ?", [@version])
      migrate!(repo)
      assert E.dump(repo) == before
      assert repo.query!("PRAGMA foreign_keys").rows == [[1]]
    end)
  end

  test "altered source index or partial helper fails closed without any mutation" do
    for mutation <- [
          "DROP INDEX workout_sessions_user_id_index",
          "CREATE TABLE coach_first_partial (id INTEGER PRIMARY KEY)"
        ] do
      E.with_db(fn repo ->
        upstream!(repo)
        E.seed_upstream!(repo)
        repo.query!(mutation)
        before = E.dump(repo)
        versions = repo.query!("SELECT * FROM schema_migrations ORDER BY version").rows
        assert_raise RuntimeError, ~r/unsupported.*coach-first/, fn -> migrate!(repo) end
        assert E.dump(repo) == before
        assert repo.query!("SELECT * FROM schema_migrations ORDER BY version").rows == versions
        assert repo.query!("PRAGMA foreign_keys").rows == [[1]]
      end)
    end
  end

  test "altered target index and trigger are not mistaken for an already applied target" do
    for mutation <- [
          "DROP INDEX workout_plans_content_hash_index",
          "DROP TRIGGER workout_sessions_identity_snapshot_immutable_trigger"
        ] do
      E.with_db(fn repo ->
        upstream!(repo)
        migrate!(repo)
        repo.query!("DELETE FROM schema_migrations WHERE version = ?", [@version])
        repo.query!(mutation)
        before = E.dump(repo)
        assert_raise RuntimeError, ~r/unsupported.*coach-first/, fn -> migrate!(repo) end
        assert E.dump(repo) == before
        assert repo.query!("PRAGMA foreign_keys").rows == [[1]]
      end)
    end
  end

  test "exact-schema retry rejects invalid facts, video hashes, pending-draft ownership and regressed sequences" do
    for mutation <- [
          :invalid_state,
          :video_type,
          :video_hash,
          :pending_owner,
          :sequence,
          :fallback
        ] do
      E.with_db(fn repo ->
        upstream!(repo)
        E.seed_upstream!(repo)
        migrate!(repo)
        repo.query!("DELETE FROM schema_migrations WHERE version = ?", [@version])

        triggers =
          repo.query!("SELECT name,sql FROM sqlite_master WHERE type = 'trigger' ORDER BY name").rows

        repo.checkout(fn ->
          Enum.each(triggers, fn [name, _] -> repo.query!("DROP TRIGGER #{name}") end)
          repo.query!("PRAGMA ignore_check_constraints = ON")

          case mutation do
            :invalid_state ->
              repo.query!("UPDATE workout_sessions SET state = 'invalid' WHERE id = 1")

            :video_type ->
              repo.query!(
                "UPDATE workout_sessions SET workout_type_snapshot = 'navy_seal' WHERE id = 2"
              )

            :video_hash ->
              repo.query!("UPDATE workout_sessions SET content_hash = 'wrong-hash' WHERE id = 2")

            :sequence ->
              repo.query!("UPDATE sqlite_sequence SET seq = 0 WHERE name = 'workout_sessions'")

            :fallback ->
              repo.query!("DELETE FROM workout_plans WHERE origin = 'built_in'")

            :pending_owner ->
              repo.query!("""
              INSERT INTO workout_plans (user_id,name,origin,state,definition_json,program_json,content_hash,burpee_type,inserted_at,updated_at)
              VALUES (2, 'Foreign draft', 'user', 'draft', '{}', '{}', 'draft-hash', 'six_count', '2026-10-05T00:00:00Z','2026-10-05T00:00:00Z')
              """)

              repo.query!("""
              INSERT INTO coach_recommendations (user_id,slot_key,slot_date,selected_workout_plan_id,pending_draft_id,inserted_at,updated_at)
              SELECT 1, 'corrupt-owner', '2026-10-05', (SELECT id FROM workout_plans WHERE origin='built_in'), id, inserted_at, updated_at FROM workout_plans WHERE name='Foreign draft'
              """)
          end

          repo.query!("PRAGMA ignore_check_constraints = OFF")
          Enum.each(triggers, fn [_, sql] -> repo.query!(sql) end)
        end)

        before = E.dump(repo)
        assert_raise RuntimeError, fn -> migrate!(repo) end
        assert E.dump(repo) == before

        assert repo.query!("SELECT version FROM schema_migrations WHERE version = ?", [@version]).rows ==
                 []

        assert repo.query!("PRAGMA foreign_keys").rows == [[1]]
      end)
    end
  end

  test "final publication, ownership, completion and source-deletion constraints enforce durable facts" do
    E.with_db(fn repo ->
      upstream!(repo)
      E.seed_upstream!(repo)
      migrate!(repo)
      [[fallback]] = repo.query!("SELECT id FROM workout_plans WHERE origin = 'built_in'").rows

      for sql <- [
            "UPDATE workout_plans SET name = 'changed' WHERE id = #{fallback}",
            "UPDATE workout_plans SET state = 'draft', published_at = NULL WHERE id = #{fallback}",
            "DELETE FROM workout_plans WHERE id = #{fallback}",
            "UPDATE workout_sessions SET note_post = 'changed' WHERE id = 1",
            "INSERT INTO workout_plans (user_id,name,origin,state,definition_json,program_json,content_hash,burpee_type,published_at,inserted_at,updated_at) VALUES (1,'bad owner','built_in','published','{}','{}','hash','six_count','2026-10-05','2026-10-05','2026-10-05')",
            "INSERT INTO workout_sessions (user_id,state,source_kind,burpee_type,inserted_at,updated_at) VALUES (1,'started','manual','six_count','2026-10-05','2026-10-05')",
            "INSERT INTO coach_recommendations (user_id,slot_key,slot_date,selected_workout_plan_id,selected_workout_video_id,inserted_at,updated_at) VALUES (1,'both','2026-10-05',#{fallback},1,'2026-10-05','2026-10-05')",
            "INSERT INTO coach_recommendations (user_id,slot_key,slot_date,selected_workout_plan_id,pending_draft_id,inserted_at,updated_at) VALUES (1,'bad draft','2026-10-05',#{fallback},#{fallback},'2026-10-05','2026-10-05')",
            "INSERT INTO workout_sessions (user_id,state,source_kind,plan_id,display_name_snapshot,workout_type_snapshot,program_snapshot,content_hash,client_session_id,started_at,burpee_type,inserted_at,updated_at) SELECT 1,'started','plan',id,name,burpee_type,'{}',content_hash,'bad-program','2026-10-05',burpee_type,'2026-10-05','2026-10-05' FROM workout_plans WHERE origin='built_in'"
          ] do
        assert_raise Exqlite.Error, fn -> repo.query!(sql) end
      end

      # Same-content published variations are legal: content_hash index is not unique.
      repo.query!("""
      INSERT INTO workout_plans (user_id,name,origin,state,definition_json,program_json,content_hash,burpee_type,published_at,inserted_at,updated_at)
      SELECT 1,'Same content variation','user','published',definition_json,program_json,content_hash,burpee_type,published_at,inserted_at,updated_at FROM workout_plans WHERE origin='built_in'
      """)

      repo.query!("""
      INSERT INTO workout_plans (user_id,name,origin,state,definition_json,program_json,content_hash,burpee_type,inserted_at,updated_at)
      VALUES (1,'Selected draft','user','draft','{}','{}','draft-hash','six_count','2026-10-05','2026-10-05')
      """)

      [[draft]] = repo.query!("SELECT id FROM workout_plans WHERE name='Selected draft'").rows

      repo.query!(
        "INSERT INTO coach_recommendations (user_id,slot_key,slot_date,selected_workout_plan_id,pending_draft_id,inserted_at,updated_at) VALUES (1,'selected-plan','2026-10-05',#{draft},#{draft},'2026-10-05','2026-10-05')"
      )

      assert_raise Exqlite.Error, fn ->
        repo.query!("DELETE FROM workout_plans WHERE id = ?", [draft])
      end

      assert_raise Exqlite.Error, fn ->
        repo.query!("UPDATE workout_plans SET user_id = 2 WHERE id = ?", [draft])
      end

      repo.query!(
        "INSERT INTO coach_recommendations (user_id,slot_key,slot_date,selected_workout_video_id,inserted_at,updated_at) VALUES (1,'selected-video','2026-10-05',1,'2026-10-05','2026-10-05')"
      )

      assert_raise Exqlite.Error, fn -> repo.query!("DELETE FROM workout_videos WHERE id = 1") end
      repo.query!("DELETE FROM coach_recommendations WHERE slot_key='selected-video'")

      before_video =
        repo.query!("SELECT video_snapshot,content_hash FROM workout_sessions WHERE id = 2").rows

      repo.query!("DELETE FROM workout_videos WHERE id = 1")

      assert repo.query!("SELECT workout_video_id FROM workout_sessions WHERE id = 2").rows == [
               [nil]
             ]

      assert repo.query!("SELECT video_snapshot,content_hash FROM workout_sessions WHERE id = 2").rows ==
               before_video

      assert repo.query!("PRAGMA foreign_key_check").rows == []
    end)
  end

  test "irreversible rollback directs operator to the verified backup" do
    unless Code.ensure_loaded?(BurpeeTrainer.Repo.Migrations.CoachFirstSchema),
      do: Code.require_file(@path)

    assert_raise RuntimeError, ~r/irreversible.*restore.*backup/, fn ->
      apply(BurpeeTrainer.Repo.Migrations.CoachFirstSchema, :down, [])
    end
  end

  def assert_preservation!(repo, facts) do
    assert repo.query!(
             "SELECT id, username, oidc_sub, timezone, timezone_provisioned FROM users ORDER BY id"
           ).rows == [
             [1, "one", "seed-one", "Etc/UTC", 0],
             [2, "two", "seed-two", "Etc/UTC", 0]
           ]

    assert repo.query!("SELECT id FROM workout_sessions ORDER BY id").rows == [
             [1],
             [2],
             [5],
             [6],
             [7]
           ]

    assert repo.query!(
             "SELECT plan_id, display_name_snapshot, program_snapshot, content_hash, goal_id, client_session_id, note_pre, note_post, mood, tags, capture_mode, cadence_ms FROM workout_sessions WHERE id = ?",
             [facts.completed_plan]
           ).rows == [
             [
               nil,
               "Seed plan",
               facts.program,
               "seed-program",
               facts.goal,
               "completed-token",
               "before",
               "after",
               4,
               "[\"seed\"]",
               "tracked",
               "[9000,9000]"
             ]
           ]

    assert repo.query!(
             "SELECT display_name_snapshot, program_snapshot, content_hash FROM workout_sessions WHERE id = 5"
           ).rows == [["Historical six count workout", facts.program, "seed-program"]]

    assert repo.query!(
             "SELECT source_kind, program_snapshot, video_snapshot, note_post FROM workout_sessions WHERE id = 6"
           ).rows == [["manual", nil, nil, "manual history"]]

    for {id, snapshot} <- [
          {facts.completed_video,
           %{
             "name" => "Seed video",
             "filename" => "seed.mp4",
             "type" => "six_count",
             "duration" => 120,
             "count" => 12,
             "format" => "follow_along"
           }},
          {7,
           %{
             "name" => "Unknown-count video",
             "filename" => "nil-count.mp4",
             "type" => "navy_seal",
             "duration" => 300,
             "count" => nil,
             "format" => "follow_along"
           }}
        ] do
      [[encoded, hash]] =
        repo.query!("SELECT video_snapshot, content_hash FROM workout_sessions WHERE id = ?", [id]).rows

      assert Jason.decode!(encoded) == snapshot

      canonical =
        "{" <>
          Enum.map_join(Enum.sort(snapshot), ",", fn {k, v} ->
            Jason.encode!(k) <> ":" <> Jason.encode!(v)
          end) <> "}"

      assert hash == Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)
    end

    assert repo.query!("SELECT id, workout_session_id FROM pose_capture_runs ORDER BY id").rows ==
             [[facts.completed_run, facts.completed_plan], [3, nil]]

    assert repo.query!("SELECT id, payload_json, payload_digest FROM pose_trace_chunks").rows == [
             [facts.completed_chunk, "{\"rep\":1}", "digest"]
           ]

    assert repo.query!(
             "SELECT id, user_id, burpee_type, burpee_count_target, duration_sec_target, date_target, burpee_count_baseline, duration_sec_baseline, date_baseline, status FROM goals"
           ).rows == [
             [facts.goal, 1, "six_count", 20, 180, "2026-10-01", 10, 120, "2026-09-01", "active"]
           ]

    assert repo.query!(
             "SELECT name,filename,burpee_type,duration_sec,burpee_count,available,format FROM workout_videos ORDER BY id"
           ).rows == [
             ["Seed video", "seed.mp4", "six_count", 120, 12, 1, "follow_along"],
             ["Unknown-count video", "nil-count.mp4", "navy_seal", 300, nil, 1, "follow_along"]
           ]

    assert repo.query!(
             "SELECT previous_best_weeks,best_week_pushups,best_session_pushups,best_pace_sec_per_burpee,lifetime_pushup_milestone FROM user_stats"
           ).rows == [[3, 100, 40, 8.5, 500]]

    assert repo.query!("SELECT name,seq FROM sqlite_sequence ORDER BY name").rows ==
             (Enum.sort(
                for table <-
                      ~w[users goals user_stats workout_videos workout_sessions pose_capture_runs pose_trace_chunks],
                    do: [table, 1000]
              ) ++ [["workout_plans", 1001]])
             |> Enum.sort()

    for table <-
          ~w[execution_programs style_performances blocks sets plan_steps coach_profiles coach_workout_threads coach_messages coach_generation_attempts coach_workout_drafts prepared_workouts coach_preparation_events execution_authorization_uses video_execution_authorization_uses] do
      assert repo.query!("SELECT name FROM sqlite_master WHERE name = ?", [table]).rows == []
    end

    for table <-
          ~w[coach_recommendations coach_settings coach_guidance_entries coach_workout_memories workout_design_entries workout_design_sessions] do
      assert repo.query!("SELECT COUNT(*) FROM #{table}").rows == [[0]]
    end

    :ok
  end

  defp upstream!(repo) do
    Ecto.Migrator.run(
      repo,
      E.migrations(@dir) |> Enum.filter(fn {v, _} -> E.upstream?(v) end),
      :up,
      all: true,
      log: false
    )
  end

  defp assert_pool_restored!(repo, supervisor) do
    parent = self()

    tasks =
      for _ <- 1..5 do
        Task.Supervisor.async_nolink(supervisor, fn ->
          repo.checkout(
            fn ->
              send(parent, {:connection, self()})

              receive do
                :check ->
                  {repo.query!("PRAGMA foreign_keys").rows,
                   repo.query!("PRAGMA foreign_key_check").rows,
                   repo.query!("SELECT name FROM sqlite_temp_master").rows}
              end
            end,
            timeout: :infinity
          )
        end)
      end

    holders =
      for _ <- 1..5 do
        assert_receive {:connection, holder}, 5_000
        holder
      end

    Enum.each(holders, &send(&1, :check))
    assert Enum.map(tasks, &Task.await(&1, 5_000)) == List.duplicate({[[1]], [], []}, 5)
  end

  defp migrate!(repo, module \\ BurpeeTrainer.Repo.Migrations.CoachFirstSchema) do
    unless Code.ensure_loaded?(BurpeeTrainer.Repo.Migrations.CoachFirstSchema),
      do: Code.require_file(@path)

    Ecto.Migrator.run(repo, [{@version, module}], :up,
      all: true,
      log: false
    )
  end
end
