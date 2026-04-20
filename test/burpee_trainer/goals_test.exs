defmodule BurpeeTrainer.GoalsTest do
  use BurpeeTrainer.DataCase, async: false

  alias BurpeeTrainer.Goals
  alias BurpeeTrainer.Goals.Goal

  import BurpeeTrainer.Fixtures

  describe "create_goal/2" do
    test "creates an active goal" do
      user = user_fixture()
      goal = goal_fixture(user)

      assert %Goal{} = goal
      assert goal.status == :active
      assert goal.user_id == user.id
    end

    test "rejects a target date that is not after the baseline date" do
      user = user_fixture()
      today = Date.utc_today()

      assert {:error, changeset} =
               Goals.create_goal(user, %{
                 "burpee_type" => "six_count",
                 "burpee_count_target" => 70,
                 "duration_sec_target" => 300,
                 "date_target" => Date.to_iso8601(today),
                 "burpee_count_baseline" => 50,
                 "duration_sec_baseline" => 240,
                 "date_baseline" => Date.to_iso8601(today)
               })

      assert %{date_target: [_ | _]} = errors_on(changeset)
    end

    test "creating a second active goal for the same burpee_type abandons the first" do
      user = user_fixture()
      first = goal_fixture(user, %{"burpee_type" => "six_count"})
      second = goal_fixture(user, %{"burpee_type" => "six_count"})

      assert Repo.get!(Goal, first.id).status == :abandoned
      assert Repo.get!(Goal, second.id).status == :active
    end

    test "an active goal for a different burpee_type is left alone" do
      user = user_fixture()
      six = goal_fixture(user, %{"burpee_type" => "six_count"})
      navy = goal_fixture(user, %{"burpee_type" => "navy_seal"})

      assert Repo.get!(Goal, six.id).status == :active
      assert Repo.get!(Goal, navy.id).status == :active
    end
  end

  describe "queries" do
    test "get_active_goal/2 returns only the active row" do
      user = user_fixture()
      first = goal_fixture(user, %{"burpee_type" => "six_count"})
      second = goal_fixture(user, %{"burpee_type" => "six_count"})

      active = Goals.get_active_goal(user, :six_count)
      assert active.id == second.id
      refute active.id == first.id
    end

    test "list_active_goals/1 returns one row per burpee_type" do
      user = user_fixture()
      _ = goal_fixture(user, %{"burpee_type" => "six_count"})
      _ = goal_fixture(user, %{"burpee_type" => "navy_seal"})

      actives = Goals.list_active_goals(user)
      assert length(actives) == 2
      assert Enum.map(actives, & &1.burpee_type) |> Enum.sort() == [:navy_seal, :six_count]
    end

    test "list_goals/1 returns both active and abandoned, scoped per user" do
      user = user_fixture()
      other = user_fixture()

      _ = goal_fixture(user, %{"burpee_type" => "six_count"})
      _ = goal_fixture(user, %{"burpee_type" => "six_count"})
      _ = goal_fixture(other, %{"burpee_type" => "six_count"})

      all = Goals.list_goals(user)
      assert length(all) == 2
      assert Enum.all?(all, &(&1.user_id == user.id))
    end

    test "get_goal!/2 scopes by user" do
      alice = user_fixture()
      bob = user_fixture()
      goal = goal_fixture(alice)

      assert Goals.get_goal!(alice, goal.id).id == goal.id
      assert_raise Ecto.NoResultsError, fn -> Goals.get_goal!(bob, goal.id) end
    end
  end

  describe "transitions" do
    test "abandon_goal/1 sets status to :abandoned" do
      user = user_fixture()
      goal = goal_fixture(user)

      {:ok, abandoned} = Goals.abandon_goal(goal)
      assert abandoned.status == :abandoned
    end

    test "mark_achieved/1 sets status to :achieved" do
      user = user_fixture()
      goal = goal_fixture(user)

      {:ok, achieved} = Goals.mark_achieved(goal)
      assert achieved.status == :achieved
    end

    test "after abandoning, a new goal for the same type can be active" do
      user = user_fixture()
      first = goal_fixture(user, %{"burpee_type" => "six_count"})
      {:ok, _} = Goals.abandon_goal(first)

      second = goal_fixture(user, %{"burpee_type" => "six_count"})
      assert second.status == :active
    end
  end
end
