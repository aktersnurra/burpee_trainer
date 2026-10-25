defmodule BurpeeTrainerWeb.Flows.QuickDurationFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession

  test "one duration tap prepares a local review and Use persists without starting", %{conn: conn} do
    scope = scope_fixture(%{"timezone" => "Etc/UTC"})
    conn = init_test_session(conn, %{user_id: scope.user.id})
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    {:ok, before} = Workouts.ensure_home_selection(scope, slot)
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()
    view |> element("#home-duration-2400") |> render_click()
    assert has_element?(view, "#home-request-confirm[aria-label='Use workout']")
    assert has_element?(view, "#home-edit-review #home-inspection")
    assert {:ok, ^before} = Workouts.ensure_home_selection(scope, slot)
    assert llm_call_count(scope) == 0
    view |> element("#home-request-confirm") |> render_click()
    render_async(view)
    assert {:ok, selected} = Workouts.ensure_home_selection(scope, slot)
    assert selected.plan.target_duration_sec == 2400
    assert selected.plan.target_reps == before.plan.target_reps * 2
    assert Repo.aggregate(WorkoutSession, :count) == 0
    {:ok, reopened, _} = live(conn, ~p"/")
    assert has_element?(reopened, "#home-summary", selected.plan.name)
    assert llm_call_count(scope) == 0
  end

  test "a duration review opened from collapsed Home can be read and cancelled", %{conn: conn} do
    scope = scope_fixture()
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    {:ok, before} = Workouts.ensure_home_selection(scope, slot)
    {:ok, view, _} = live(init_test_session(conn, %{user_id: scope.user.id}), ~p"/")
    render_click(view, "choose_duration", %{"seconds" => "2400"})

    assert has_element?(
             view,
             "#home-expansion-content[aria-hidden=false]:not([inert]) #home-edit-review"
           )

    view |> element("#home-request-abort") |> render_click()
    refute has_element?(view, "#home-edit-review")
    assert {:ok, ^before} = Workouts.ensure_home_selection(scope, slot)
    assert Repo.aggregate(WorkoutSession, :count) == 0
    assert llm_call_count(scope) == 0
  end

  test "weekly minutes and comparable pace do not require both movements", %{conn: conn} do
    scope = scope_fixture(%{"timezone" => "Etc/UTC"})
    now = DateTime.utc_now(:second)

    free_form_session_fixture(scope.user, %{
      burpee_count_actual: 180,
      duration_sec_actual: 2400,
      completed_at: DateTime.add(now, -7, :day)
    })

    free_form_session_fixture(scope.user, %{
      burpee_count_actual: 100,
      duration_sec_actual: 1200,
      completed_at: now
    })

    free_form_session_fixture(user_fixture(), %{
      burpee_count_actual: 300,
      duration_sec_actual: 1200
    })

    {:ok, view, _} = live(init_test_session(conn, %{user_id: scope.user.id}), ~p"/progress")
    assert has_element?(view, "#home-week-remaining", "60 min left")
    assert has_element?(view, "#progress-pace-six_count[data-reps-per-20='100']", "+10")
    assert has_element?(view, "#progress-pace-navy_seal", "No comparable sessions")
    refute has_element?(view, "#progress-pace-navy_seal[data-reps-per-20='0']")
  end
end
