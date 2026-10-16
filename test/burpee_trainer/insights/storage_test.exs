defmodule BurpeeTrainer.Insights.StorageTest do
  use BurpeeTrainer.DataCase, async: true
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Insights

  @insight %{"headline" => "Session saved", "points" => []}
  test "one immutable result per completed owned session; reads and writes scoped" do
    scope = scope_fixture()
    foreign = scope_fixture()
    session = free_form_session_fixture(scope.user)
    assert {:ok, saved} = Insights.store(scope, session.id, @insight, "fallback")

    assert {:ok, replay} =
             Insights.store(scope, session.id, %{@insight | "headline" => "Different"}, "llm")

    assert saved.id == replay.id
    assert replay.headline == "Session saved"
    assert Insights.for_session(scope, session.id).id == saved.id
    assert Insights.for_session(foreign, session.id) == nil
    assert Insights.latest(foreign) == nil
    assert {:error, :session_not_owned} = Insights.store(foreign, session.id, @insight, "llm")
    assert Insights.latest(scope).id == saved.id
  end

  test "latest uses completed local day not insertion time; deletion cascades insight" do
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user_fixture(), "America/New_York")
    scope = BurpeeTrainer.Accounts.Scope.for_user(user)
    assert scope.user.timezone == "America/New_York"

    previous =
      free_form_session_fixture(scope.user, %{"completed_at" => ~U[2026-10-07 03:59:00Z]})

    current = free_form_session_fixture(scope.user, %{"completed_at" => ~U[2026-10-07 04:01:00Z]})

    tomorrow =
      free_form_session_fixture(scope.user, %{"completed_at" => ~U[2026-10-08 04:01:00Z]})

    for session <- [tomorrow, current, previous] do
      assert {:ok, _} = Insights.store(scope, session.id, @insight, "fallback")
    end

    assert Insights.latest(scope, ~U[2026-10-07 12:00:00Z]).session_id == current.id
    assert Insights.latest(scope, ~U[2026-10-07 03:59:30Z]).session_id == previous.id
    assert {:ok, _} = BurpeeTrainer.Workouts.delete_session(scope, current)
    assert Insights.for_session(scope, current.id) == nil
    assert Insights.latest(scope, ~U[2026-10-07 12:00:00Z]) == nil
    assert Insights.for_session(scope, previous.id)
  end
end
