defmodule BurpeeTrainerWeb.AppFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Workouts.WorkoutSession

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "Home Start creates one exact immutable session before the runner mounts", %{
    conn: conn,
    user: user
  } do
    {:ok, slot} =
      BurpeeTrainer.Coach.Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))

    assert {:ok, _recommendation} =
             Workouts.ensure_recommendation(Scope.for_user(user), %{
               slot_key: slot.slot_key,
               slot_date: slot.slot_date,
               rationale: "Ready from Home."
             })

    {:ok, home, _html} = live(conn, ~p"/")

    assert has_element?(home, "#home-action[aria-label='Start workout'] .hero-play-solid")
    home |> element("#home-summary") |> render_click()
    home |> element("#home-action") |> render_click()
    started = Workouts.current_started_session(Scope.for_user(user))
    # A user with no completed session starts the starter, not the placeholder fallback.
    assert {:ok, %{name: "Starter Six-Count"} = plan} =
             Workouts.get_library_plan(Scope.for_user(user), started.plan_id)

    assert started.program_snapshot == plan.program_json
    assert started.content_hash == plan.content_hash

    assert_redirect(home, ~p"/session/#{started.id}")
    assert Repo.aggregate(WorkoutSession, :count) == 1

    {:ok, runner, _html} = live(conn, ~p"/session/#{started.id}")

    assert has_element?(
             runner,
             "#burpee-session[data-session-id='#{started.id}'][data-content-hash='#{started.content_hash}'][data-source-kind='plan'][data-session-program]"
           )

    for id <- ~w[
      session-camera-setup
      session-runner-client
      session-completion-review
    ] do
      assert has_element?(runner, "##{id}[data-session-panel]")
    end

    assert Repo.aggregate(WorkoutSession, :count) == 1
  end
end
