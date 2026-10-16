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

  test "Home shows the planner's reason under the workout", %{conn: conn, user: user} do
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    {:ok, selection} = BurpeeTrainer.Workouts.ensure_home_selection(Scope.for_user(user), slot)

    Repo.update_all(
      from(r in BurpeeTrainer.Workouts.CoachRecommendation,
        where: r.id == ^selection.recommendation_id
      ),
      set: [rationale: "An easy twenty minutes to find your rhythm."]
    )

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-planner-rationale", "An easy twenty minutes")
  end

  test "Start is the one filled action and the others are quiet icons", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-action.home-primary-action .hero-play-solid")

    for {id, label, icon} <- [
          {"home-edit-workout", "Edit current workout", "hero-pencil-square"},
          {"home-title-action", "Switch workout", "hero-arrows-right-left"},
          {"home-new-workout", "New workout", "hero-plus"}
        ] do
      assert has_element?(view, "##{id}.home-text-action[aria-label='#{label}'] .#{icon}")
    end

    refute has_element?(view, "#home-ready-recommendation .hero-play, .home-action-label")
  end
end
