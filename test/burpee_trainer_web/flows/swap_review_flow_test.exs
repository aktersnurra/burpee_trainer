defmodule BurpeeTrainerWeb.Flows.SwapReviewFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession

  setup %{conn: conn} do
    scope = scope_fixture()
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    {:ok, selected} = Workouts.ensure_home_selection(scope, slot)
    plan = plan_fixture(scope.user, %{target_reps: 40, target_duration_sec: 1200})
    {:ok, view, _} = live(init_test_session(conn, %{user_id: scope.user.id}), ~p"/")
    view |> element("#home-summary") |> render_click()
    view |> element("#home-title-action") |> render_click()
    %{view: view, scope: scope, slot: slot, selected: selected, plan: plan}
  end

  test "preview and cancel preserve selection; explicit Use selects without starting", ctx do
    ctx.view |> element("#home-alternative-plan-#{ctx.plan.id}-select") |> render_click()
    assert has_element?(ctx.view, "#home-swap-review #home-inspection")
    assert {:ok, unchanged} = Workouts.ensure_home_selection(ctx.scope, ctx.slot)
    assert unchanged == ctx.selected
    ctx.view |> element("#home-swap-abort") |> render_click()
    assert has_element?(ctx.view, "#home-summary", ctx.selected.plan.name)
    ctx.view |> element("#home-title-action") |> render_click()
    ctx.view |> element("#home-alternative-plan-#{ctx.plan.id}-select") |> render_click()
    ctx.view |> element("#home-swap-confirm") |> render_click()
    assert {:ok, selected} = Workouts.ensure_home_selection(ctx.scope, ctx.slot)
    assert selected.plan.id == ctx.plan.id
    assert Repo.aggregate(WorkoutSession, :count) == 0
  end

  test "a newer choice in another tab is not overwritten by Use", ctx do
    ctx.view |> element("#home-alternative-plan-#{ctx.plan.id}-select") |> render_click()
    other = plan_fixture(ctx.scope.user)
    {:ok, newer} = Workouts.select_home_workout(ctx.scope, ctx.selected, other.id)
    ctx.view |> element("#home-swap-confirm") |> render_click()
    assert {:ok, ^newer} = Workouts.ensure_home_selection(ctx.scope, ctx.slot)
    assert has_element?(ctx.view, "#home-adjustment-error", "no longer available")
  end
end
