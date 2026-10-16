defmodule BurpeeTrainer.Workouts.StarterSelectionTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts

  setup do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    %{user: user, slot: slot}
  end

  test "a user with no completed session gets the starter for the slot's burpee type",
       %{user: user, slot: slot} do
    for {type, name} <- [six_count: "Starter Six-Count", navy_seal: "Starter Navy Seal"] do
      slot = %{slot | burpee_type: type, slot_key: "starter-#{type}"}
      {:ok, selection} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
      assert %{origin: :built_in, name: ^name, burpee_type: ^type} = selection.plan

      # A fresh user is level 1A, so the starter is too (and the chooser's default filter shows it).
      assert BurpeeTrainer.Levels.level_for_count(type, selection.plan.target_reps) == :level_1a
    end
  end

  test "a user with a completed session keeps the Steady 10 fallback", %{user: user} do
    session_from_plan_fixture(user, plan_fixture(user))
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    {:ok, selection} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    assert %{origin: :built_in, name: "Built-in Steady 10"} = selection.plan
  end
end
