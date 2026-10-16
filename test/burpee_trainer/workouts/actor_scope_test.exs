defmodule BurpeeTrainer.Workouts.ActorScopeTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Repo, Workouts}

  test "get_session accepts the owner Scope without exposing foreign or invalid rows" do
    owner = scope_fixture()
    foreign = scope_fixture()
    session = free_form_session_fixture(owner.user)
    before = Repo.reload!(session)

    assert Workouts.get_session(owner, session.id).id == session.id
    assert Workouts.get_session(foreign, session.id) == nil
    assert Workouts.get_session(owner, session.id + 1_000_000) == nil

    for id <- [nil, "invalid", 0, -1] do
      assert Workouts.get_session(owner, id) == nil
    end

    assert Repo.reload!(session) == before
  end
end
