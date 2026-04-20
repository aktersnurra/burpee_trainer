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

    test "create_plan/2 requires warmup reps and rounds when warmup_enabled is true" do
      user = user_fixture()

      assert {:error, changeset} =
               Workouts.create_plan(user, %{
                 "name" => "Warmup missing",
                 "burpee_type" => "six_count",
                 "warmup_enabled" => true,
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

      errors = errors_on(changeset)
      assert errors[:warmup_reps] && errors[:warmup_rounds]
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

    test "create_plan/2 rejects shave-off larger than available end-of-set rest" do
      user = user_fixture()

      assert {:error, changeset} =
               Workouts.create_plan(user, %{
                 "name" => "Too greedy",
                 "burpee_type" => "six_count",
                 "warmup_enabled" => false,
                 "shave_off_sec" => 10,
                 "shave_off_block_count" => 1,
                 "blocks" => [
                   %{
                     "position" => 1,
                     "repeat_count" => 1,
                     "sets" => [
                       %{
                         "position" => 1,
                         "burpee_count" => 5,
                         "sec_per_rep" => 3.0,
                         "sec_per_burpee" => 3.0,
                         "end_of_set_rest" => 5
                       }
                     ]
                   },
                   %{
                     "position" => 2,
                     "repeat_count" => 1,
                     "sets" => [
                       %{
                         "position" => 1,
                         "burpee_count" => 5,
                         "sec_per_rep" => 3.0,
                         "sec_per_burpee" => 3.0,
                         "end_of_set_rest" => 0
                       }
                     ]
                   }
                 ]
               })

      assert %{shave_off_sec: [msg | _]} = errors_on(changeset)
      assert msg =~ "not enough rest"
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

    test "list_recent_sessions/3 respects the limit" do
      user = user_fixture()

      for _ <- 1..4 do
        free_form_session_fixture(user, %{"burpee_type" => "six_count"})
      end

      recent = Workouts.list_recent_sessions(user, :six_count, 2)
      assert length(recent) == 2
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
end
