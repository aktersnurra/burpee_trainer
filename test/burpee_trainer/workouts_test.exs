defmodule BurpeeTrainer.WorkoutsTest do
  use BurpeeTrainer.DataCase, async: false

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}

  import BurpeeTrainer.Fixtures

  describe "plans" do
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

    test "create_plan/2 rejects a plan without a name" do
      user = user_fixture()

      assert {:error, changeset} =
               Workouts.create_plan(user, %{
                 "name" => "",
                 "burpee_type" => "six_count",
                 "blocks" => [
                   %{
                     "position" => 1,
                     "repeat_count" => 1,
                     "sets" => [
                       %{
                         "position" => 1,
                         "burpee_count" => 5,
                         "sec_per_rep" => 6.0,
                         "sec_per_burpee" => 3.0,
                         "end_of_set_rest" => 0
                       }
                     ]
                   }
                 ]
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

    test "update_plan/2 replaces blocks (on_replace: :delete)" do
      user = user_fixture()
      plan = plan_fixture(user)

      {:ok, updated} =
        Workouts.update_plan(plan, %{
          "name" => "Renamed",
          "blocks" => [
            %{
              "position" => 1,
              "repeat_count" => 2,
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
      assert [block] = updated.blocks
      assert block.repeat_count == 2
      assert [set] = block.sets
      assert set.burpee_count == 5
    end

    test "duplicate_plan/1 creates an independent copy with suffixed name" do
      user = user_fixture()
      plan = plan_fixture(user, %{"name" => "Original"})

      {:ok, copy} = Workouts.duplicate_plan(plan)

      assert copy.id != plan.id
      assert copy.name == "Original (copy)"
      assert copy.user_id == user.id
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

      # warmup session — must not count
      {:ok, _} =
        Workouts.create_warmup_session(user, %{
          burpee_type: :six_count,
          burpee_count_done: 5,
          duration_sec: 3600
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
end
