defmodule BurpeeTrainerWeb.HomeFirstUseTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite

  import Ecto.Query
  import Phoenix.LiveViewTest
  import BurpeeTrainerWeb.StudioHelpers
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

  # Planning follows events (a completed or logged session, Retry); opening the app is not
  # one, even on a day that shows the fallback.
  test "opening Home never plans", %{conn: conn, user: user} do
    free_form_session_fixture(user, %{
      completed_at: DateTime.add(DateTime.utc_now(:second), -2, :day)
    })

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "[data-home-state=start] [data-primary-action=start]")
    {:ok, _view, _html} = live(conn, ~p"/")

    assert all_enqueued(worker: PlanNextWorkoutJob) == []
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

  test "a stale delete in the normal chooser reports the failure in place", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user, %{target_reps: 10})
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()
    open_swap(view)
    {:ok, _} = BurpeeTrainer.Workouts.archive_plan(Scope.for_user(user), plan.id)

    view |> element("#home-delete-workout-#{plan.id}") |> render_click()

    assert has_element?(
             view,
             "#home-alternatives-panel:not([hidden]) #home-chooser-error[role=alert]"
           )

    assert_push_event(view, "home_chooser_rejected", %{})
    assert has_element?(view, "#home-action")
  end

  test "Start is the one filled action; its toggles are quiet icons and nothing else is there", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-action.home-primary-action .hero-play-solid")

    for {id, label, icon} <- [
          {"home-start-camera", "Camera tracking", "hero-video-camera"},
          {"home-start-warmup", "Warmup", "hero-fire"}
        ] do
      assert has_element?(view, "##{id}.home-text-action[aria-label*='#{label}'] .#{icon}") or
               has_element?(view, "##{id}.home-text-action .#{icon}")
    end

    # Edit, swap and new are asked for (a swipe, or the handle), not shown.
    refute has_element?(view, "#home-edit-workout, #home-title-action, #home-new-workout")
    refute has_element?(view, "#home-ready-recommendation .hero-play, .home-action-label")
  end
end
