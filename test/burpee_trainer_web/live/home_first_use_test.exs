defmodule BurpeeTrainerWeb.HomeFirstUseTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite

  import Ecto.Query
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Policy, PlanNextWorkoutJob}

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "a fresh user opens on a ready starter workout", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "[data-home-state=start] [data-primary-action=start]")
    assert render(view) =~ "Starter Six-Count"
    refute has_element?(view, "#home-bootstrap-form")
  end

  test "mounting plans the slot once, whatever happened to the first job", %{
    conn: conn,
    user: user
  } do
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    {:ok, _view, _html} = live(conn, ~p"/")

    assert [%{args: %{"user_id" => user_id, "slot_key" => slot_key}}] =
             all_enqueued(worker: PlanNextWorkoutJob)

    assert {user_id, slot_key} == {user.id, slot.slot_key}

    Repo.update_all(from(job in Oban.Job), set: [state: "cancelled"])
    {:ok, _view, _html} = live(conn, ~p"/")

    assert Repo.aggregate(
             from(job in Oban.Job, where: job.worker == ^inspect(PlanNextWorkoutJob)),
             :count
           ) ==
             1
  end
end
