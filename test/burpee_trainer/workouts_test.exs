defmodule BurpeeTrainer.WorkoutsTest do
  use BurpeeTrainer.DataCase, async: false

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.{PoseCaptureRun, WorkoutPlan, WorkoutSession}

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

    test "create_plan/2 persists plan with blocks and sets" do
      user = user_fixture()
      plan = plan_fixture(user)

      assert %WorkoutPlan{} = plan
      assert plan.user_id == user.id
      assert [block] = plan.blocks
      assert length(block.sets) == 3
    end

    test "create_plan/2 preserves the last set's end_of_set_rest (it is part of the set's duration)" do
      user = user_fixture()

      plan =
        plan_fixture(user, %{
          "blocks" => [
            %{
              "position" => 1,
              "repeat_count" => 1,
              "sets" => [
                %{
                  "position" => 1,
                  "burpee_count" => 10,
                  "sec_per_rep" => 6.0,
                  "sec_per_burpee" => 3.0,
                  "end_of_set_rest" => 30
                },
                %{
                  "position" => 2,
                  "burpee_count" => 10,
                  "sec_per_rep" => 6.0,
                  "sec_per_burpee" => 3.0,
                  "end_of_set_rest" => 99
                }
              ]
            }
          ]
        })

      [last_set | _] = Enum.sort_by(hd(plan.blocks).sets, & &1.position, :desc)
      assert last_set.end_of_set_rest == 99
    end

    test "create_plan/2 persists generated plan metadata" do
      user = user_fixture()

      plan =
        plan_fixture(user, %{
          "coach_suggestion_kind" => "recommended",
          "coach_target_reps" => 150,
          "plan_solver_metadata" => %{
            "solver_version" => "intelligence-v2",
            "explanation" => ["Generated from coach target."]
          }
        })

      assert plan.coach_suggestion_kind == "recommended"
      assert plan.coach_target_reps == 150
      assert plan.plan_solver_metadata["solver_version"] == "intelligence-v2"
      assert plan.plan_solver_metadata["explanation"] == ["Generated from coach target."]
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

    test "save_generated_plan/2 preserves v3 solver metadata" do
      user = user_fixture()

      assert {:ok, solution} =
               BurpeeTrainer.PlanSolver.solve(%BurpeeTrainer.PlanSolver.Input{
                 name: "Generated",
                 burpee_type: :six_count,
                 target_duration_min: 10,
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

      assert metadata_value(saved.plan_solver_metadata, :solver_version) == 3
      assert metadata_value(saved.plan_solver_metadata, :structure_key) == "1x[60]"
    end

    test "duplicate_plan/1 creates an independent copy with suffixed name and metadata" do
      user = user_fixture()

      plan =
        plan_fixture(user, %{
          "name" => "Original",
          "coach_suggestion_kind" => "recommended",
          "coach_target_reps" => 100,
          "plan_solver_metadata" => %{"source" => "coach_target"}
        })

      {:ok, copy} = Workouts.duplicate_plan(plan)

      assert copy.id != plan.id
      assert copy.name == "Original (copy)"
      assert copy.user_id == user.id
      assert copy.coach_suggestion_kind == "recommended"
      assert copy.coach_target_reps == 100
      assert copy.plan_solver_metadata == %{"source" => "coach_target"}
      assert length(copy.blocks) == length(plan.blocks)
    end

    test "delete_plan/1 cascades blocks and sets" do
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
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata || %{}, key) || Map.get(metadata || %{}, Atom.to_string(key))
  end
end
