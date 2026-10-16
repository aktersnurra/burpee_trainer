defmodule BurpeeTrainer.GoalsTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Goals, Repo}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Goals.Goal

  test "scope_fixture wraps the persisted fixture user" do
    scope = scope_fixture()

    assert %Scope{user: user} = scope
    assert Repo.get!(BurpeeTrainer.Accounts.User, user.id).id == user.id
  end

  test "get_active_goal scopes active goals to the actor and burpee type" do
    user = user_fixture()
    scope = Scope.for_user(user)
    foreign_user = user_fixture()

    assert Goals.get_active_goal(scope, :six_count) == nil

    own_active = goal_fixture(user)
    _foreign_active = goal_fixture(foreign_user)

    inactive =
      %Goal{user_id: user.id}
      |> Goal.changeset(%{
        "burpee_type" => "navy_seal",
        "burpee_count_target" => 40,
        "duration_sec_target" => 300,
        "date_target" => Date.to_iso8601(Date.add(Date.utc_today(), 28)),
        "burpee_count_baseline" => 20,
        "duration_sec_baseline" => 240,
        "date_baseline" => Date.to_iso8601(Date.utc_today()),
        "status" => "achieved"
      })
      |> Repo.insert!()

    assert %Goal{id: own_id} = Goals.get_active_goal(scope, :six_count)
    assert own_id == own_active.id
    assert Goals.get_active_goal(scope, :navy_seal) == nil
    assert Repo.get!(Goal, inactive.id).status == :achieved
  end
end
