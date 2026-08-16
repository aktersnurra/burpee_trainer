defmodule BurpeeTrainer.WorkoutsTest do
  use BurpeeTrainer.DataCase, async: false

  alias BurpeeTrainer.{ExecutionPrograms, PlanCompiler, Repo, Workouts}
  alias BurpeeTrainer.Workouts.{ExecutionProgram, PoseCaptureRun, WorkoutPlan, WorkoutSession}

  import BurpeeTrainer.Fixtures

  describe "capture mode classification" do
    setup do
      {:ok, user: user_fixture()}
    end

    test "free-form sessions are logged", %{user: user} do
      {:ok, session} =
        Workouts.create_free_form_session(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => "20",
          "duration_sec_actual" => "1200"
        })

      assert session.capture_mode == :logged
      assert session.cadence_ms == nil
      assert session.target_pace_sec == nil
      assert session.pace_consistency == nil
    end

    test "planned sessions are timed by default", %{user: user} do
      plan = plan_fixture(user)

      {:ok, session} =
        Workouts.create_session_from_plan(user, plan, %{
          "burpee_type" => "six_count",
          "burpee_count_planned" => "30",
          "duration_sec_planned" => "90",
          "burpee_count_actual" => "30",
          "duration_sec_actual" => "90"
        })

      assert session.capture_mode == :timed
      assert session.cadence_ms == nil
    end
  end

  describe "tracked session capture" do
    setup do
      user = user_fixture()
      plan = plan_fixture(user)
      {:ok, user: user, plan: plan}
    end

    test "tracked plan session stores cadence and consistency", %{user: user, plan: plan} do
      {:ok, session} =
        Workouts.create_tracked_session_from_plan(user, plan, %{
          "burpee_type" => "six_count",
          "burpee_count_planned" => "3",
          "duration_sec_planned" => "15",
          "burpee_count_actual" => "3",
          "duration_sec_actual" => "15",
          "target_pace_sec" => "5.0",
          "cadence_ms" => [5000, 10000, 15000]
        })

      assert session.capture_mode == :tracked
      assert session.cadence_ms == "[5000,10000,15000]"
      assert session.target_pace_sec == 5.0
      assert session.pace_consistency == 1.0
    end

    test "tracked plan session rejects length mismatch", %{user: user, plan: plan} do
      assert {:error, changeset} =
               Workouts.create_tracked_session_from_plan(user, plan, %{
                 "burpee_type" => "six_count",
                 "burpee_count_planned" => "3",
                 "duration_sec_planned" => "15",
                 "burpee_count_actual" => "3",
                 "duration_sec_actual" => "15",
                 "cadence_ms" => [5000, 10000]
               })

      assert %{cadence_ms: ["must contain one timestamp per rep"]} = errors_on(changeset)
    end

    test "tracked plan session rejects timestamps after duration", %{user: user, plan: plan} do
      assert {:error, changeset} =
               Workouts.create_tracked_session_from_plan(user, plan, %{
                 "burpee_type" => "six_count",
                 "burpee_count_planned" => "3",
                 "duration_sec_planned" => "15",
                 "burpee_count_actual" => "3",
                 "duration_sec_actual" => "15",
                 "cadence_ms" => [5000, 10000, 16000]
               })

      assert %{cadence_ms: ["must finish within session duration"]} = errors_on(changeset)
    end

    test "manual camera correction saves tracked without cadence analytics", %{
      user: user,
      plan: plan
    } do
      assert {:ok, session} =
               Workouts.create_tracked_session_from_plan(
                 user,
                 plan,
                 %{
                   "burpee_count_actual" => 4,
                   "duration_sec_actual" => 15,
                   "client_session_id" => Ecto.UUID.generate(),
                   "cadence_ms" => [5_000, 10_000, 15_000],
                   "target_pace_sec" => "5.0"
                 },
                 :manual_correction
               )

      assert session.capture_mode == :tracked
      assert session.burpee_count_actual == 4
      assert session.cadence_ms == nil
      assert session.target_pace_sec == nil
      assert session.pace_consistency == nil
    end

    test "trusted camera result retains strict cadence validation", %{user: user, plan: plan} do
      assert {:error, changeset} =
               Workouts.create_tracked_session_from_plan(
                 user,
                 plan,
                 %{
                   "burpee_count_actual" => 4,
                   "duration_sec_actual" => 15,
                   "client_session_id" => Ecto.UUID.generate()
                 },
                 {:trusted, [5_000, 10_000, 15_000], 5.0}
               )

      assert "must contain one timestamp per rep" in errors_on(changeset).cadence_ms
    end

    test "trusted camera result rejects non-numeric cadence without crashing", %{
      user: user,
      plan: plan
    } do
      assert {:error, changeset} =
               Workouts.create_tracked_session_from_plan(
                 user,
                 plan,
                 %{
                   "burpee_count_actual" => 3,
                   "duration_sec_actual" => 15,
                   "client_session_id" => Ecto.UUID.generate()
                 },
                 {:trusted, ["bad", "cadence", "values"], 5.0}
               )

      assert "must be monotonic non-negative timestamps" in errors_on(changeset).cadence_ms
    end
  end

  describe "plans" do
    test "creating a plan stores source_json and current execution program" do
      user = user_fixture()

      attrs = %{
        "name" => "100 in 20",
        "source_json" => %{
          "burpee_type" => "six_count",
          "target_reps" => 100,
          "target_duration_sec" => 1_200,
          "pacing_style" => "even",
          "block_pattern" => [10],
          "explicit_rests" => [
            %{"target_elapsed_sec" => 600, "duration_sec" => 60, "tolerance_sec" => 90}
          ]
        }
      }

      assert {:ok, plan} = Workouts.create_plan(user, attrs)
      assert %WorkoutPlan{} = plan
      assert plan.user_id == user.id
      assert plan.source_json["target_reps"] == 100
      assert plan.current_execution_program_id
    end

    test "compile_plan lazily upgrades a legacy execution program" do
      user = user_fixture()
      plan = plan_fixture(user)
      current_program = ExecutionPrograms.get!(plan.current_execution_program_id)

      legacy_program_json =
        Map.update!(current_program.program_json, "events", fn events ->
          Enum.map(events, &Map.drop(&1, ["sec_per_burpee_us"]))
        end)

      legacy_program =
        %ExecutionProgram{}
        |> ExecutionProgram.changeset(%{
          content_hash: "legacy-#{System.unique_integer([:positive])}",
          schema_version: 1,
          solver_version: current_program.solver_version,
          burpee_type: current_program.burpee_type,
          target_reps: current_program.target_reps,
          target_duration_sec: current_program.target_duration_sec,
          event_count: current_program.event_count,
          program_json: legacy_program_json,
          summary_json: current_program.summary_json
        })
        |> Repo.insert!()

      plan =
        plan
        |> Ecto.Changeset.change(current_execution_program_id: legacy_program.id)
        |> Repo.update!()

      assert {:ok, upgraded_program} = Workouts.compile_plan(plan)
      assert upgraded_program.schema_version == PlanCompiler.schema_version()
      assert upgraded_program.id != legacy_program.id
      assert Repo.reload(plan).current_execution_program_id == upgraded_program.id

      assert Enum.all?(upgraded_program.program_json["events"], fn
               %{"kind" => "work"} = event -> Map.has_key?(event, "sec_per_burpee_us")
               _event -> true
             end)

      legacy_only_plan = %{
        plan
        | id: nil,
          source_json: nil,
          current_execution_program_id: legacy_program.id
      }

      assert {:ok, fallback_program} = Workouts.compile_plan(legacy_only_plan)
      assert fallback_program.id == legacy_program.id
    end

    test "create_plan/2 requires explicit source_json instead of legacy execution fields" do
      user = user_fixture()

      assert {:error, %BurpeeTrainer.PlanCompiler.CompileError{code: :invalid_source}} =
               Workouts.create_plan(user, %{
                 "name" => "Legacy-only plan",
                 "burpee_type" => "six_count",
                 "burpee_count_target" => 10,
                 "target_duration_min" => 2,
                 "pacing_style" => "even"
               })
    end

    test "creating an unbroken source-backed plan preserves source pacing style" do
      user = user_fixture()

      assert {:ok, plan} =
               Workouts.create_plan(user, %{
                 "name" => "Unbroken source",
                 "source_json" => %{
                   "burpee_type" => "six_count",
                   "target_reps" => 20,
                   "target_duration_sec" => 300,
                   "pacing_style" => "unbroken",
                   "max_unbroken_reps" => 5,
                   "explicit_rests" => []
                 }
               })

      assert plan.pacing_style == :unbroken
      assert plan.source_json["pacing_style"] == "unbroken"
      assert plan.current_execution_program_id
    end

    test "deleting a plan preserves performed session facts" do
      user = user_fixture()

      assert {:ok, plan} =
               Workouts.create_plan(user, %{
                 "name" => "10 in 2",
                 "source_json" => %{
                   "burpee_type" => "six_count",
                   "target_reps" => 10,
                   "target_duration_sec" => 120,
                   "pacing_style" => "even",
                   "block_pattern" => [10],
                   "explicit_rests" => []
                 }
               })

      program = BurpeeTrainer.ExecutionPrograms.get!(plan.current_execution_program_id)

      assert {:ok, session} =
               Workouts.create_session_from_plan(user, plan, %{
                 "burpee_count_actual" => 10,
                 "duration_sec_actual" => 118,
                 "client_session_id" => Ecto.UUID.generate(),
                 "execution_program_id" => program.id
               })

      assert {:ok, _plan} = Workouts.delete_plan(plan)
      session = Workouts.get_session!(user, session.id)

      assert session.plan_id == nil
      assert session.execution_program_id == program.id
      assert session.burpee_count_actual == 10
    end

    test "source-backed plan sessions link the compiled program when current id is missing" do
      user = user_fixture()

      assert {:ok, plan} =
               Workouts.create_plan(user, %{
                 "name" => "Source without current program",
                 "source_json" => %{
                   "burpee_type" => "six_count",
                   "target_reps" => 12,
                   "target_duration_sec" => 144,
                   "pacing_style" => "even",
                   "block_pattern" => [6],
                   "explicit_rests" => []
                 }
               })

      original_program_id = plan.current_execution_program_id
      plan = Repo.update!(Ecto.Changeset.change(plan, current_execution_program_id: nil))
      assert plan.current_execution_program_id == nil

      assert {:ok, session} =
               Workouts.create_session_from_plan(user, plan, %{
                 "burpee_count_actual" => 12,
                 "duration_sec_actual" => 140,
                 "client_session_id" => Ecto.UUID.generate()
               })

      assert session.execution_program_id == original_program_id
      assert session.burpee_count_planned == 12
      assert session.duration_sec_planned == 144
    end

    test "create_plan/2 persists source and current execution program" do
      user = user_fixture()
      plan = plan_fixture(user)

      assert %WorkoutPlan{} = plan
      assert plan.user_id == user.id
      assert plan.source_json["target_reps"] > 0
      assert plan.current_execution_program_id

      program = ExecutionPrograms.get!(plan.current_execution_program_id)
      assert program.target_reps == plan.source_json["target_reps"]
    end

    test "create_plan/2 keeps explicit rests in source and compiled program" do
      user = user_fixture()

      plan =
        plan_fixture(user, %{
          "source_json" => %{
            "burpee_type" => "six_count",
            "target_reps" => 20,
            "target_duration_sec" => 240,
            "pacing_style" => "even",
            "block_pattern" => [10],
            "explicit_rests" => [
              %{"target_elapsed_sec" => 120, "duration_sec" => 30, "tolerance_sec" => 60}
            ]
          }
        })

      assert [%{"duration_sec" => 30}] = plan.source_json["explicit_rests"]

      program = ExecutionPrograms.get!(plan.current_execution_program_id)

      assert Enum.any?(program.program_json["events"], fn event ->
               event["kind"] == "rest" and event["duration_ms"] == 30_000
             end)
    end

    test "create_plan/2 persists coach attribution without solver metadata column" do
      user = user_fixture()

      plan =
        plan_fixture(user, %{
          "coach_suggestion_kind" => "recommended",
          "coach_target_reps" => 150
        })

      assert plan.coach_suggestion_kind == "recommended"
      assert plan.coach_target_reps == 150
      assert plan.plan_solver_metadata == nil
    end

    test "create_plan/2 rejects a source-backed plan without a name" do
      user = user_fixture()

      assert {:error, changeset} =
               Workouts.create_plan(user, %{
                 "name" => "",
                 "source_json" => %{
                   "burpee_type" => "six_count",
                   "target_reps" => 5,
                   "target_duration_sec" => 60,
                   "pacing_style" => "even",
                   "block_pattern" => [5],
                   "explicit_rests" => []
                 }
               })

      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "get_plan!/2 scopes by user" do
      alice = user_fixture()
      bob = user_fixture()
      plan = plan_fixture(alice)

      assert Workouts.get_plan!(alice, plan.id).id == plan.id

      assert_raise Ecto.NoResultsError, fn ->
        Workouts.get_plan!(bob, plan.id)
      end
    end

    test "list_plans/1 returns only this user's plans, most-recent first" do
      alice = user_fixture()
      bob = user_fixture()

      _bob_plan = plan_fixture(bob, %{"name" => "Bob"})
      alice_plan_a = plan_fixture(alice, %{"name" => "A"})
      alice_plan_b = plan_fixture(alice, %{"name" => "B"})

      ids = Enum.map(Workouts.list_plans(alice), & &1.id)
      assert alice_plan_a.id in ids
      assert alice_plan_b.id in ids
      refute Enum.any?(Workouts.list_plans(alice), &(&1.user_id == bob.id))
    end

    test "update_plan/2 recompiles source and stores the new current program" do
      user = user_fixture()
      plan = plan_fixture(user)
      original_program_id = plan.current_execution_program_id

      {:ok, updated} =
        Workouts.update_plan(plan, %{
          "name" => "Renamed",
          "source_json" => %{
            "burpee_type" => "six_count",
            "target_reps" => 5,
            "target_duration_sec" => 60,
            "pacing_style" => "even",
            "block_pattern" => [5],
            "explicit_rests" => []
          },
          "blocks" => [
            %{
              "position" => 1,
              "repeat_count" => 1,
              "sets" => [
                %{
                  "position" => 1,
                  "burpee_count" => 5,
                  "sec_per_rep" => 4.0,
                  "sec_per_burpee" => 3.0,
                  "end_of_set_rest" => 0
                }
              ]
            }
          ]
        })

      updated = Workouts.get_plan!(user, updated.id)
      assert updated.name == "Renamed"
      assert updated.source_json["target_reps"] == 5
      assert updated.current_execution_program_id
      refute updated.current_execution_program_id == original_program_id
    end

    test "save_generated_plan/2 persists generated source and current program" do
      user = user_fixture()

      assert {:ok, solution} =
               BurpeeTrainer.PlanSolver.generate_plan(%BurpeeTrainer.PlanSolver.Input{
                 name: "Generated",
                 burpee_type: :six_count,
                 target_duration_sec: 600,
                 burpee_count_target: 60,
                 pacing_style: :even,
                 level: :level_1c
               })

      assert metadata_value(solution.plan.plan_solver_metadata, :solver_version) == 3

      source_json = %{
        "burpee_type" => "six_count",
        "target_reps" => 60,
        "target_duration_sec" => 600,
        "pacing_style" => "even",
        "block_pattern" => [60],
        "explicit_rests" => []
      }

      assert {:ok, saved} =
               Workouts.save_generated_plan(user, %{solution.plan | source_json: source_json})

      saved = Workouts.get_plan!(user, saved.id)

      assert saved.source_json == source_json
      assert saved.current_execution_program_id
      assert ExecutionPrograms.get!(saved.current_execution_program_id).target_reps == 60
    end

    test "duplicate_plan/1 creates an independent copy with suffixed name and source" do
      user = user_fixture()

      plan =
        plan_fixture(user, %{
          "name" => "Original",
          "coach_suggestion_kind" => "recommended",
          "coach_target_reps" => 100
        })

      {:ok, copy} = Workouts.duplicate_plan(plan)

      assert copy.id != plan.id
      assert copy.name == "Original (copy)"
      assert copy.user_id == user.id
      assert copy.source_json == plan.source_json
      assert copy.current_execution_program_id
      assert copy.coach_suggestion_kind == nil
      assert copy.coach_target_reps == nil
    end

    test "delete_plan/1 deletes the source plan" do
      user = user_fixture()
      plan = plan_fixture(user)

      assert {:ok, _} = Workouts.delete_plan(plan)
      assert_raise Ecto.NoResultsError, fn -> Workouts.get_plan!(user, plan.id) end
    end
  end

  describe "sessions" do
    test "create_session_from_plan/3 derives planned fields from the plan" do
      user = user_fixture()

      plan =
        plan_fixture(user, %{
          "burpee_type" => "navy_seal",
          "source_json" => %{
            "burpee_type" => "navy_seal",
            "target_reps" => 4,
            "target_duration_sec" => 45,
            "pacing_style" => "even",
            "block_pattern" => [4],
            "explicit_rests" => []
          },
          "blocks" => [
            %{
              "position" => 1,
              "repeat_count" => 1,
              "sets" => [
                %{
                  "position" => 1,
                  "burpee_count" => 4,
                  "sec_per_rep" => 10.0,
                  "sec_per_burpee" => 10.0,
                  "end_of_set_rest" => 5
                }
              ]
            }
          ]
        })

      {:ok, session} =
        Workouts.create_session_from_plan(user, plan, %{
          "burpee_type" => "six_count",
          "burpee_count_planned" => "999",
          "duration_sec_planned" => "999",
          "burpee_count_actual" => "4",
          "duration_sec_actual" => "45"
        })

      assert session.burpee_type == :navy_seal
      assert session.burpee_count_planned == 4
      assert session.duration_sec_planned == 45
    end

    test "create_session_from_plan/3 rejects another user's plan" do
      alice = user_fixture()
      bob = user_fixture()
      bob_plan = plan_fixture(bob)

      assert {:error, :not_found} =
               Workouts.create_session_from_plan(alice, bob_plan, %{
                 "burpee_count_actual" => "30",
                 "duration_sec_actual" => "90"
               })
    end

    test "create_tracked_session_from_plan/3 rejects another user's plan" do
      alice = user_fixture()
      bob = user_fixture()
      bob_plan = plan_fixture(bob)

      assert {:error, :not_found} =
               Workouts.create_tracked_session_from_plan(alice, bob_plan, %{
                 "burpee_count_actual" => "3",
                 "duration_sec_actual" => "15",
                 "cadence_ms" => [5000, 10000, 15000]
               })
    end

    test "create_session_from_plan/3 persists planned + actual fields" do
      user = user_fixture()
      plan = plan_fixture(user)

      session =
        session_from_plan_fixture(user, plan, %{
          "burpee_count_actual" => 28,
          "duration_sec_actual" => 130
        })

      assert %WorkoutSession{} = session
      assert session.user_id == user.id
      assert session.plan_id == plan.id
      assert session.burpee_count_actual == 28
      assert session.duration_sec_actual == 130
      assert session.client_session_id
    end

    test "create_session_from_plan/3 is idempotent for the same client session id" do
      user = user_fixture()
      plan = plan_fixture(user)
      client_session_id = Ecto.UUID.generate()

      attrs = %{
        "client_session_id" => client_session_id,
        "burpee_count_actual" => 28,
        "duration_sec_actual" => 130
      }

      assert {:ok, first} = Workouts.create_session_from_plan(user, plan, attrs)
      assert {:ok, second} = Workouts.create_session_from_plan(user, plan, attrs)

      assert first.id == second.id
      assert first.client_session_id == client_session_id
      assert length(Workouts.list_sessions(user)) == 1
    end

    test "create_tracked_session_from_plan/3 is idempotent for the same client session id" do
      user = user_fixture()
      plan = plan_fixture(user)
      client_session_id = Ecto.UUID.generate()

      attrs = %{
        "client_session_id" => client_session_id,
        "burpee_count_actual" => "3",
        "duration_sec_actual" => "15",
        "cadence_ms" => [5_000, 10_000, 15_000]
      }

      assert {:ok, first} = Workouts.create_tracked_session_from_plan(user, plan, attrs)
      assert {:ok, second} = Workouts.create_tracked_session_from_plan(user, plan, attrs)

      assert first.id == second.id
      assert first.client_session_id == client_session_id
      assert length(Workouts.list_sessions(user)) == 1
    end

    test "delete_session/2 removes only the user's session" do
      alice = user_fixture()
      bob = user_fixture()
      alice_plan = plan_fixture(alice)
      bob_plan = plan_fixture(bob)
      alice_session = session_from_plan_fixture(alice, alice_plan)
      bob_session = session_from_plan_fixture(bob, bob_plan)

      assert {:error, :not_found} = Workouts.delete_session(alice, bob_session.id)
      assert {:ok, deleted} = Workouts.delete_session(alice, alice_session.id)

      assert deleted.id == alice_session.id
      refute Repo.get(WorkoutSession, alice_session.id)
      assert Repo.get(WorkoutSession, bob_session.id)
    end

    test "delete_session/2 removes linked tracked capture data" do
      user = user_fixture()
      plan = plan_fixture(user)

      {:ok, session} =
        Workouts.create_tracked_session_from_plan(user, plan, %{
          "burpee_count_actual" => "1",
          "duration_sec_actual" => "5",
          "cadence_ms" => [5_000]
        })

      {:ok, run} = Workouts.start_pose_capture_run(user, plan)
      {:ok, run} = Workouts.complete_pose_capture_run(user, run, session)

      assert Repo.get(PoseCaptureRun, run.id)
      assert {:ok, _deleted} = Workouts.delete_session(user, session.id)

      refute Repo.get(WorkoutSession, session.id)
      refute Repo.get(PoseCaptureRun, run.id)
    end

    test "create_free_form_session/2 leaves planned fields nil" do
      user = user_fixture()
      session = free_form_session_fixture(user)

      assert session.plan_id == nil
      assert session.burpee_count_planned == nil
      assert session.duration_sec_planned == nil
    end

    test "list_sessions/2 filters by burpee_type" do
      user = user_fixture()
      _ = free_form_session_fixture(user, %{"burpee_type" => "six_count"})
      navy = free_form_session_fixture(user, %{"burpee_type" => "navy_seal"})

      navy_only = Workouts.list_sessions(user, :navy_seal)
      assert Enum.map(navy_only, & &1.id) == [navy.id]
    end

    test "list_sessions/1 only returns this user's rows" do
      alice = user_fixture()
      bob = user_fixture()

      _ = free_form_session_fixture(alice)
      _ = free_form_session_fixture(bob)

      user_ids = Enum.map(Workouts.list_sessions(alice), & &1.user_id) |> Enum.uniq()
      assert user_ids == [alice.id]
    end
  end

  describe "durable workout lifecycle" do
    test "a running plan session accepts nil actuals but a report requires them" do
      user = user_fixture()
      plan = plan_fixture(user)

      start_changeset =
        WorkoutSession.start_changeset(
          %WorkoutSession{user_id: user.id, plan_id: plan.id},
          %{
            client_session_id: Ecto.UUID.generate(),
            source: :plan,
            burpee_type: :six_count,
            burpee_count_planned: 30,
            duration_sec_planned: 120
          }
        )

      assert start_changeset.valid?
      assert Ecto.Changeset.get_field(start_changeset, :status) == :running
      assert Ecto.Changeset.get_field(start_changeset, :burpee_count_actual) == nil
      assert Ecto.Changeset.get_field(start_changeset, :duration_sec_actual) == nil

      report_changeset =
        start_changeset
        |> Ecto.Changeset.apply_changes()
        |> WorkoutSession.report_changeset(%{})

      refute report_changeset.valid?

      assert %{burpee_count_actual: ["can't be blank"], duration_sec_actual: ["can't be blank"]} =
               errors_on(report_changeset)
    end

    test "aborting a session records the abort time without browser attrs" do
      changeset = WorkoutSession.abort_changeset(%WorkoutSession{})

      assert Ecto.Changeset.get_change(changeset, :status) == :aborted
      assert %DateTime{} = Ecto.Changeset.get_change(changeset, :aborted_at)
    end

    test "only one unresolved session may be inserted for a user" do
      user = user_fixture()
      plan = plan_fixture(user)

      assert {:ok, _session} =
               %WorkoutSession{user_id: user.id, plan_id: plan.id}
               |> WorkoutSession.start_changeset(running_plan_attrs())
               |> Repo.insert()

      assert {:error, changeset} =
               %WorkoutSession{user_id: user.id, plan_id: plan.id}
               |> WorkoutSession.start_changeset(running_plan_attrs())
               |> Repo.insert()

      assert %{user_id: [_]} = errors_on(changeset)
    end

    test "begin_plan_session/3 persists server-derived running data and is idempotent" do
      user = user_fixture()
      plan = plan_fixture(user)
      client_session_id = Ecto.UUID.generate()

      assert {:ok, first} = Workouts.begin_plan_session(user, plan, client_session_id)
      assert first.status == :running
      assert first.source == :plan
      assert first.plan_id == plan.id
      assert first.execution_program_id
      assert first.burpee_type == :six_count
      assert first.burpee_count_planned == 30
      assert first.duration_sec_planned == 1200
      assert first.burpee_count_actual == nil
      assert first.duration_sec_actual == nil

      assert {:ok, second} = Workouts.begin_plan_session(user, plan, client_session_id)
      assert second.id == first.id

      assert {:error, {:unresolved_session, unresolved}} =
               Workouts.begin_plan_session(user, plan, Ecto.UUID.generate())

      assert unresolved.id == first.id
      assert %{plan: %WorkoutPlan{}, video: nil} = Workouts.get_unresolved_session(user)
    end

    test "begin_video_session/3 persists video-derived source data" do
      user = user_fixture()

      video =
        video_fixture(%{
          burpee_type: :navy_seal,
          duration_sec: 75,
          burpee_count: 12
        })

      assert {:ok, session} = Workouts.begin_video_session(user, video, Ecto.UUID.generate())
      assert session.status == :running
      assert session.source == :video
      assert session.video_id == video.id
      assert session.burpee_type == :navy_seal
      assert session.duration_sec_planned == 75
      assert session.burpee_count_planned == 12
    end

    test "mark_report_pending/2 atomically transitions a running session and preserves terminal rows" do
      user = user_fixture()
      plan = plan_fixture(user)
      client_session_id = Ecto.UUID.generate()

      assert {:ok, running} = Workouts.begin_plan_session(user, plan, client_session_id)
      assert {:ok, pending} = Workouts.mark_report_pending(user, client_session_id)
      assert pending.id == running.id
      assert pending.status == :report_pending
      assert %DateTime{} = pending.report_pending_at

      assert {:ok, replayed} = Workouts.mark_report_pending(user, client_session_id)
      assert replayed.id == pending.id
      assert replayed.report_pending_at == pending.report_pending_at

      assert {:ok, aborted} = Workouts.abort_session(user, client_session_id)
      assert aborted.status == :aborted
      assert {:error, :aborted} = Workouts.mark_report_pending(user, client_session_id)

      reported_id = Ecto.UUID.generate()
      assert {:ok, reported} = Workouts.begin_plan_session(user, plan, reported_id)
      handler_id = {:mark_report_pending_cas, make_ref()}
      test_pid = self()
      ref = make_ref()

      task =
        Task.async(fn ->
          send(test_pid, {:mark_report_pending_task, self()})

          receive do
            :mark_report_pending -> Workouts.mark_report_pending(user, reported_id)
          end
        end)

      assert_receive {:mark_report_pending_task, task_pid}

      :ok =
        :telemetry.attach(
          handler_id,
          [:burpee_trainer, :repo, :query],
          fn _event,
             _measurements,
             _metadata,
             %{handler_id: handler_id, ref: ref, task_pid: task_pid, test_pid: test_pid} ->
            if self() == task_pid and Process.get(handler_id) != true do
              Process.put(handler_id, true)
              send(test_pid, {:mark_report_pending_read, ref, self()})

              receive do
                {:continue_mark_report_pending, ^ref} -> :ok
              end
            end
          end,
          %{handler_id: handler_id, ref: ref, task_pid: task_pid, test_pid: test_pid}
        )

      try do
        send(task_pid, :mark_report_pending)
        assert_receive {:mark_report_pending_read, ^ref, handler_pid}

        Repo.update_all(
          from(s in WorkoutSession, where: s.id == ^reported.id),
          set: [status: :reported, reported_at: DateTime.utc_now(:second)]
        )

        send(handler_pid, {:continue_mark_report_pending, ref})

        assert {:ok, persisted} = Task.await(task)
        assert persisted.status == :reported
        assert persisted.report_pending_at == nil
      after
        :telemetry.detach(handler_id)
      end
    end

    test "report_session/4 reports original running or pending row idempotently" do
      user = user_fixture()
      plan = plan_fixture(user)

      report_attrs = %{
        "burpee_count_actual" => "27",
        "duration_sec_actual" => "123",
        "note_post" => "finished",
        "mood" => "1",
        "tags" => "test"
      }

      running_id = Ecto.UUID.generate()
      assert {:ok, running} = Workouts.begin_plan_session(user, plan, running_id)

      assert {:ok, reported, :reported} =
               Workouts.report_session(user, running_id, report_attrs, %{})

      assert reported.id == running.id
      assert reported.status == :reported
      assert reported.capture_mode == :timed
      assert %DateTime{} = reported.reported_at
      assert is_binary(reported.report_fingerprint)

      assert {:ok, replayed, :existing} =
               Workouts.report_session(user, running_id, report_attrs, %{})

      assert replayed.id == reported.id

      assert {:error, :report_conflict} =
               Workouts.report_session(
                 user,
                 running_id,
                 Map.put(report_attrs, "burpee_count_actual", "28"),
                 %{}
               )

      assert Repo.get!(WorkoutSession, reported.id).burpee_count_actual == 27

      pending_id = Ecto.UUID.generate()
      assert {:ok, pending} = Workouts.begin_plan_session(user, plan, pending_id)
      assert {:ok, _} = Workouts.mark_report_pending(user, pending_id)

      assert {:ok, pending_reported, :reported} =
               Workouts.report_session(user, pending_id, report_attrs, %{})

      assert pending_reported.id == pending.id
    end

    test "immediate facts exclude running lifecycle rows" do
      user = user_fixture()
      plan = plan_fixture(user)
      reported = free_form_session_fixture(user, %{"duration_sec_actual" => 120})
      last_week = Date.add(Date.beginning_of_week(Date.utc_today(), :monday), -7)

      Repo.update_all(
        from(s in WorkoutSession, where: s.id == ^reported.id),
        set: [inserted_at: DateTime.new!(last_week, ~T[10:00:00], "Etc/UTC")]
      )

      assert {:ok, running} = Workouts.begin_plan_session(user, plan, Ecto.UUID.generate())

      assert [listed] = Workouts.list_sessions(user)
      assert listed.id == reported.id
      assert [%{week_start: ^last_week, minutes: 2.0}] = Workouts.weekly_minutes(user)
      assert Workouts.this_week_trained_days(user) == MapSet.new()
      assert running.status == :running
    end

    test "paginated history excludes running, report-pending, and aborted lifecycle rows" do
      user = user_fixture()
      plan = plan_fixture(user)
      older = free_form_session_fixture(user)
      newer = free_form_session_fixture(user)
      older_at = ~U[2026-01-01 10:00:00Z]
      newer_at = ~U[2026-01-02 10:00:00Z]

      Repo.update_all(
        from(s in WorkoutSession, where: s.id == ^older.id),
        set: [inserted_at: older_at]
      )

      Repo.update_all(
        from(s in WorkoutSession, where: s.id == ^newer.id),
        set: [inserted_at: newer_at]
      )

      assert {:ok, running} = Workouts.begin_plan_session(user, plan, Ecto.UUID.generate())
      assert {[first], true} = Workouts.list_sessions_page(user, 1)
      assert first.id == newer.id
      assert {[second], false} = Workouts.list_sessions_page(user, 1, before: newer_at)
      assert second.id == older.id

      Repo.update_all(
        from(s in WorkoutSession, where: s.id == ^running.id),
        set: [status: :aborted, aborted_at: DateTime.utc_now(:second)]
      )

      assert {:ok, pending} = Workouts.begin_plan_session(user, plan, Ecto.UUID.generate())
      assert {:ok, _} = Workouts.mark_report_pending(user, pending.client_session_id)
      assert {[listed], true} = Workouts.list_sessions_page(user, 1)
      assert listed.id == newer.id
    end

    test "reporting derives fields from a prior reported fact, not its running row" do
      user = user_fixture()
      plan = plan_fixture(user)

      prior =
        free_form_session_fixture(user, %{
          "burpee_count_actual" => 10,
          "duration_sec_actual" => 60
        })

      two_days_ago = Date.add(Date.utc_today(), -2)

      Repo.update_all(
        from(s in WorkoutSession, where: s.id == ^prior.id),
        set: [inserted_at: DateTime.new!(two_days_ago, ~T[10:00:00], "Etc/UTC")]
      )

      client_session_id = Ecto.UUID.generate()
      assert {:ok, _running} = Workouts.begin_plan_session(user, plan, client_session_id)

      assert {:ok, reported, :reported} =
               Workouts.report_session(
                 user,
                 client_session_id,
                 %{"burpee_count_actual" => 20, "duration_sec_actual" => 60},
                 %{}
               )

      assert reported.days_since_last == 2
      assert reported.rate_delta == 10.0
    end

    test "terminal transitions use the current persisted result" do
      user = user_fixture()
      plan = plan_fixture(user)
      aborted_id = Ecto.UUID.generate()
      reported_id = Ecto.UUID.generate()

      assert {:ok, aborted} = Workouts.begin_plan_session(user, plan, aborted_id)

      Repo.update_all(
        from(s in WorkoutSession, where: s.id == ^aborted.id),
        set: [status: :aborted, aborted_at: DateTime.utc_now(:second)]
      )

      assert {:error, :aborted} =
               Workouts.report_session(
                 user,
                 aborted_id,
                 %{"burpee_count_actual" => 10, "duration_sec_actual" => 60},
                 %{}
               )

      assert Repo.get!(WorkoutSession, aborted.id).status == :aborted

      assert {:ok, reported} = Workouts.begin_plan_session(user, plan, reported_id)

      Repo.update_all(
        from(s in WorkoutSession, where: s.id == ^reported.id),
        set: [status: :reported, reported_at: DateTime.utc_now(:second)]
      )

      assert {:error, :already_reported} = Workouts.abort_session(user, reported_id)
      assert Repo.get!(WorkoutSession, reported.id).status == :reported
    end

    test "abort_session/2 is idempotent and rejects reported rows" do
      user = user_fixture()
      plan = plan_fixture(user)
      aborted_id = Ecto.UUID.generate()

      assert {:ok, _} = Workouts.begin_plan_session(user, plan, aborted_id)
      assert {:ok, aborted} = Workouts.abort_session(user, aborted_id)
      assert aborted.status == :aborted
      assert %DateTime{} = aborted.aborted_at
      assert {:ok, replayed} = Workouts.abort_session(user, aborted_id)
      assert replayed.id == aborted.id

      reported_id = Ecto.UUID.generate()
      assert {:ok, _} = Workouts.begin_plan_session(user, plan, reported_id)

      assert {:ok, _reported, :reported} =
               Workouts.report_session(
                 user,
                 reported_id,
                 %{
                   "burpee_count_actual" => "10",
                   "duration_sec_actual" => "60"
                 },
                 %{}
               )

      assert {:error, :already_reported} = Workouts.abort_session(user, reported_id)
    end

    test "change_session_for_report/2 preserves the lifecycle row source fields" do
      user = user_fixture()
      plan = plan_fixture(user)
      assert {:ok, session} = Workouts.begin_plan_session(user, plan, Ecto.UUID.generate())

      changeset =
        Workouts.change_session_for_report(session, %{
          "burpee_count_actual" => "10",
          "duration_sec_actual" => "60"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :plan_id) == plan.id
      assert Ecto.Changeset.get_field(changeset, :source) == :plan
      assert Ecto.Changeset.get_field(changeset, :burpee_count_planned) == 30
    end

    test "legacy direct session creation remains reported with source and capture mode" do
      user = user_fixture()
      plan = plan_fixture(user)

      assert {:ok, plan_session} =
               Workouts.create_session_from_plan(user, plan, %{
                 "burpee_count_actual" => "10",
                 "duration_sec_actual" => "60"
               })

      assert plan_session.status == :reported
      assert plan_session.source == :plan
      assert plan_session.capture_mode == :timed
      assert %DateTime{} = plan_session.reported_at

      assert {:ok, free_form_session} =
               Workouts.create_free_form_session(user, %{
                 "burpee_type" => "six_count",
                 "burpee_count_actual" => "10",
                 "duration_sec_actual" => "60"
               })

      assert free_form_session.status == :reported
      assert free_form_session.source == :manual
      assert free_form_session.capture_mode == :logged
      assert %DateTime{} = free_form_session.reported_at
    end

    defp running_plan_attrs do
      %{
        client_session_id: Ecto.UUID.generate(),
        source: :plan,
        burpee_type: :six_count,
        burpee_count_planned: 30,
        duration_sec_planned: 120
      }
    end
  end

  describe "reported-only fact reads" do
    test "keeps baseline, PB, chart, and gamification reads limited to reported facts" do
      user = user_fixture()
      plan = plan_fixture(user)

      reported =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 100,
          "duration_sec_actual" => 1200,
          "inserted_at" => ~U[2026-01-01 10:00:00Z]
        })

      for status <- [:running, :report_pending, :aborted] do
        client_session_id = Ecto.UUID.generate()
        assert {:ok, lifecycle} = Workouts.begin_plan_session(user, plan, client_session_id)

        if status == :report_pending do
          assert {:ok, _} = Workouts.mark_report_pending(user, client_session_id)
        end

        Repo.update_all(
          from(s in WorkoutSession, where: s.id == ^lifecycle.id),
          set: [
            status: status,
            burpee_count_actual: 300,
            duration_sec_actual: 1200,
            inserted_at: ~U[2026-01-02 10:00:00Z]
          ]
        )

        assert Workouts.last_session_for_type(user, :six_count).id == reported.id
        assert Workouts.best_qualifying_session(user, :six_count).id == reported.id
        assert [chart_session] = Workouts.list_sessions_for_chart(user, :six_count)
        assert chart_session.id == reported.id
        assert Workouts.current_week_pushups(user, ~D[2026-01-01]) == 100

        assert Workouts.session_milestones(user, %{lifecycle | status: status}, ~D[2026-01-01]) ==
                 []

        Repo.update_all(
          from(s in WorkoutSession, where: s.id == ^lifecycle.id),
          set: [status: :aborted, aborted_at: DateTime.utc_now(:second)]
        )
      end
    end
  end

  describe "last_session_for_type/2" do
    test "returns most recent qualifying session (20 min ± 10 sec, positive burpees)" do
      user = user_fixture()

      _old =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 10,
          "duration_sec_actual" => 1190
        })

      recent =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 25,
          "duration_sec_actual" => 1210
        })

      result = Workouts.last_session_for_type(user, :six_count)
      assert result.id == recent.id
    end

    test "returns nil when no sessions exist for the type" do
      user = user_fixture()

      _other =
        free_form_session_fixture(user, %{
          "burpee_type" => "navy_seal",
          "burpee_count_actual" => 20,
          "duration_sec_actual" => 1200
        })

      assert Workouts.last_session_for_type(user, :six_count) == nil
    end

    test "does not return sessions outside 20 min ± 10 sec window" do
      user = user_fixture()

      _too_short =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 30,
          "duration_sec_actual" => 1189
        })

      _too_long =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 30,
          "duration_sec_actual" => 1211
        })

      assert Workouts.last_session_for_type(user, :six_count) == nil
    end

    test "returns session within 20 min ± 10 sec window" do
      user = user_fixture()

      s =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 30,
          "duration_sec_actual" => 1200
        })

      assert Workouts.last_session_for_type(user, :six_count).id == s.id
    end

    test "does not return sessions with zero burpee_count_actual" do
      user = user_fixture()

      _zero =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 0,
          "duration_sec_actual" => 1200
        })

      assert Workouts.last_session_for_type(user, :six_count) == nil
    end

    test "does not return sessions from another user" do
      user1 = user_fixture()
      user2 = user_fixture()

      _s =
        free_form_session_fixture(user1, %{
          "burpee_type" => "six_count",
          "duration_sec_actual" => 1200
        })

      assert Workouts.last_session_for_type(user2, :six_count) == nil
    end
  end

  describe "weekly_minutes/1" do
    test "returns empty list when user has no sessions" do
      user = user_fixture()
      assert Workouts.weekly_minutes(user) == []
    end

    test "groups sessions into correct ISO weeks" do
      user = user_fixture()

      # Week of 2026-04-20 (Mon) — 30 min total
      free_form_session_fixture(user, %{
        "duration_sec_actual" => 1800,
        "inserted_at" => ~U[2026-04-21 10:00:00Z]
      })

      # Same week — another 30 min → total 60 min
      free_form_session_fixture(user, %{
        "duration_sec_actual" => 1800,
        "inserted_at" => ~U[2026-04-23 10:00:00Z]
      })

      # Week of 2026-04-27 (Mon) — 90 min total
      free_form_session_fixture(user, %{
        "duration_sec_actual" => 5400,
        "inserted_at" => ~U[2026-04-28 10:00:00Z]
      })

      weeks = Workouts.weekly_minutes(user)
      assert length(weeks) == 2

      [w1, w2] = weeks
      assert w1.week_start == ~D[2026-04-27]
      assert_in_delta w1.minutes, 90.0, 0.1
      assert w1.met_goal == true

      assert w2.week_start == ~D[2026-04-20]
      assert_in_delta w2.minutes, 60.0, 0.1
      assert w2.met_goal == false
    end

    test "excludes warmup-tagged sessions" do
      user = user_fixture()

      # 90 min main session
      free_form_session_fixture(user, %{"duration_sec_actual" => 5400})

      # legacy warmup-tagged session — must not count
      free_form_session_fixture(user, %{
        "burpee_count_actual" => 5,
        "duration_sec_actual" => 3600,
        "tags" => "warmup"
      })

      [week] = Workouts.weekly_minutes(user)
      assert_in_delta week.minutes, 90.0, 0.1
    end

    test "met_goal is true at exactly 80 min" do
      user = user_fixture()
      free_form_session_fixture(user, %{"duration_sec_actual" => 4800})

      [week] = Workouts.weekly_minutes(user)
      assert week.met_goal == true
    end

    test "scopes to user — other users' sessions not included" do
      alice = user_fixture()
      bob = user_fixture()

      free_form_session_fixture(alice, %{"duration_sec_actual" => 5400})
      free_form_session_fixture(bob, %{"duration_sec_actual" => 5400})

      assert length(Workouts.weekly_minutes(alice)) == 1
      assert length(Workouts.weekly_minutes(bob)) == 1
    end
  end

  describe "list_sessions_for_chart/2" do
    test "returns empty list when user has no sessions" do
      user = user_fixture()
      assert Workouts.list_sessions_for_chart(user, :six_count) == []
    end

    test "returns sessions with positive burpee_count_actual and duration_sec_actual, oldest first" do
      user = user_fixture()

      s1 =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 200,
          "duration_sec_actual" => 1200,
          "inserted_at" => ~U[2026-04-01 10:00:00Z]
        })

      s2 =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 250,
          "duration_sec_actual" => 1200,
          "inserted_at" => ~U[2026-04-08 10:00:00Z]
        })

      result = Workouts.list_sessions_for_chart(user, :six_count)
      assert length(result) == 2
      assert Enum.at(result, 0).id == s1.id
      assert Enum.at(result, 1).id == s2.id
    end

    test "excludes sessions with nil or zero burpee_count_actual" do
      user = user_fixture()

      _zero =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 0,
          "duration_sec_actual" => 1200
        })

      assert Workouts.list_sessions_for_chart(user, :six_count) == []
    end

    test "excludes sessions with nil or zero duration_sec_actual" do
      user = user_fixture()

      _zero_dur =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 200,
          "duration_sec_actual" => 0
        })

      assert Workouts.list_sessions_for_chart(user, :six_count) == []
    end

    test "only returns sessions for the given burpee_type" do
      user = user_fixture()

      _six =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 200,
          "duration_sec_actual" => 1200
        })

      _seal =
        free_form_session_fixture(user, %{
          "burpee_type" => "navy_seal",
          "burpee_count_actual" => 100,
          "duration_sec_actual" => 1200
        })

      six_results = Workouts.list_sessions_for_chart(user, :six_count)
      assert length(six_results) == 1
      assert hd(six_results).burpee_type == :six_count
    end

    test "does not return sessions from another user" do
      user1 = user_fixture()
      user2 = user_fixture()

      free_form_session_fixture(user1, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 200,
        "duration_sec_actual" => 1200
      })

      assert Workouts.list_sessions_for_chart(user2, :six_count) == []
    end
  end

  describe "best_qualifying_session/2" do
    test "returns nil when no sessions exist" do
      user = user_fixture()
      assert Workouts.best_qualifying_session(user, :six_count) == nil
    end

    test "returns the session with the highest burpee_count_actual" do
      user = user_fixture()

      _lower =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 200,
          "duration_sec_actual" => 1200,
          "inserted_at" => ~U[2026-04-10 10:00:00Z]
        })

      best =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 280,
          "duration_sec_actual" => 1200,
          "inserted_at" => ~U[2026-04-17 10:00:00Z]
        })

      result = Workouts.best_qualifying_session(user, :six_count)
      assert result.id == best.id
    end

    test "excludes sessions outside the 20-min ±10 sec window" do
      user = user_fixture()

      _short =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 300,
          "duration_sec_actual" => 600,
          "inserted_at" => ~U[2026-04-10 10:00:00Z]
        })

      assert Workouts.best_qualifying_session(user, :six_count) == nil
    end

    test "only returns sessions for the given burpee_type" do
      user = user_fixture()

      _seal =
        free_form_session_fixture(user, %{
          "burpee_type" => "navy_seal",
          "burpee_count_actual" => 150,
          "duration_sec_actual" => 1200,
          "inserted_at" => ~U[2026-04-10 10:00:00Z]
        })

      assert Workouts.best_qualifying_session(user, :six_count) == nil
    end

    test "does not return sessions from another user" do
      user1 = user_fixture()
      user2 = user_fixture()

      free_form_session_fixture(user1, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 250,
        "duration_sec_actual" => 1200,
        "inserted_at" => ~U[2026-04-10 10:00:00Z]
      })

      assert Workouts.best_qualifying_session(user2, :six_count) == nil
    end
  end

  describe "this_week_trained_days/1" do
    setup do
      {:ok, user: user_fixture()}
    end

    test "returns date of a session completed this week", %{user: user} do
      today = Date.utc_today()
      week_start = Date.beginning_of_week(today, :monday)

      plan = plan_fixture(user)
      session = session_from_plan_fixture(user, plan)

      BurpeeTrainer.Repo.update_all(
        from(s in BurpeeTrainer.Workouts.WorkoutSession, where: s.id == ^session.id),
        set: [inserted_at: DateTime.new!(week_start, ~T[10:00:00], "Etc/UTC")]
      )

      days = Workouts.this_week_trained_days(user)
      assert MapSet.member?(days, week_start)
      assert MapSet.size(days) == 1
    end

    test "ignores warmup sessions", %{user: user} do
      today = Date.utc_today()
      week_start = Date.beginning_of_week(today, :monday)

      plan = plan_fixture(user)
      session = session_from_plan_fixture(user, plan, %{"tags" => "warmup"})

      BurpeeTrainer.Repo.update_all(
        from(s in BurpeeTrainer.Workouts.WorkoutSession, where: s.id == ^session.id),
        set: [inserted_at: DateTime.new!(week_start, ~T[10:00:00], "Etc/UTC")]
      )

      days = Workouts.this_week_trained_days(user)
      assert MapSet.size(days) == 0
    end

    test "ignores sessions from previous weeks", %{user: user} do
      today = Date.utc_today()
      last_week = Date.add(Date.beginning_of_week(today, :monday), -7)

      plan = plan_fixture(user)
      session = session_from_plan_fixture(user, plan)

      BurpeeTrainer.Repo.update_all(
        from(s in BurpeeTrainer.Workouts.WorkoutSession, where: s.id == ^session.id),
        set: [inserted_at: DateTime.new!(last_week, ~T[10:00:00], "Etc/UTC")]
      )

      days = Workouts.this_week_trained_days(user)
      assert MapSet.size(days) == 0
    end

    test "returns empty MapSet when no sessions exist", %{user: user} do
      assert Workouts.this_week_trained_days(user) == MapSet.new()
    end
  end

  describe "last_run_plan/1" do
    setup do
      {:ok, user: user_fixture()}
    end

    test "returns plan from the most recent non-warmup session", %{user: user} do
      plan1 = plan_fixture(user, %{name: "Plan A"})
      plan2 = plan_fixture(user, %{name: "Plan B"})

      session1 = session_from_plan_fixture(user, plan1)
      session2 = session_from_plan_fixture(user, plan2)

      # Make session1 older
      BurpeeTrainer.Repo.update_all(
        from(s in BurpeeTrainer.Workouts.WorkoutSession, where: s.id == ^session1.id),
        set: [inserted_at: ~U[2026-01-01 10:00:00Z]]
      )

      BurpeeTrainer.Repo.update_all(
        from(s in BurpeeTrainer.Workouts.WorkoutSession, where: s.id == ^session2.id),
        set: [inserted_at: ~U[2026-01-02 10:00:00Z]]
      )

      result = Workouts.last_run_plan(user)
      assert result.id == plan2.id
      assert result.name == "Plan B"
      assert is_list(result.blocks)
    end

    test "returns nil when no sessions with a plan exist", %{user: user} do
      assert Workouts.last_run_plan(user) == nil
    end

    test "ignores warmup sessions", %{user: user} do
      plan = plan_fixture(user)
      session = session_from_plan_fixture(user, plan, %{"tags" => "warmup"})

      BurpeeTrainer.Repo.update_all(
        from(s in BurpeeTrainer.Workouts.WorkoutSession, where: s.id == ^session.id),
        set: [inserted_at: ~U[2026-01-02 10:00:00Z]]
      )

      assert Workouts.last_run_plan(user) == nil
    end

    test "excludes running, report-pending, and aborted plan sessions", %{user: user} do
      reported_plan = plan_fixture(user, %{name: "Reported"})
      lifecycle_plan = plan_fixture(user, %{name: "Lifecycle"})
      reported = session_from_plan_fixture(user, reported_plan)

      Repo.update_all(
        from(s in WorkoutSession, where: s.id == ^reported.id),
        set: [inserted_at: ~U[2026-01-01 10:00:00Z]]
      )

      client_session_id = Ecto.UUID.generate()
      assert {:ok, running} = Workouts.begin_plan_session(user, lifecycle_plan, client_session_id)
      assert Workouts.last_run_plan(user).id == reported_plan.id

      assert {:ok, pending} = Workouts.mark_report_pending(user, client_session_id)
      assert pending.id == running.id
      assert Workouts.last_run_plan(user).id == reported_plan.id

      Repo.update_all(
        from(s in WorkoutSession, where: s.id == ^pending.id),
        set: [status: :aborted, aborted_at: DateTime.utc_now(:second)]
      )

      assert Workouts.last_run_plan(user).id == reported_plan.id
    end
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata || %{}, key) || Map.get(metadata || %{}, Atom.to_string(key))
  end
end
