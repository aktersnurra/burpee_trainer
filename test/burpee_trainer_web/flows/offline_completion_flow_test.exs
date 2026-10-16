defmodule BurpeeTrainerWeb.Flows.OfflineCompletionFlowTest do
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

  test "a retry after a lost completion acknowledgement is acknowledged without rewriting", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user)
    token = Ecto.UUID.generate()
    assert {:ok, started} = Workouts.start_plan(Scope.for_user(user), plan.id, token)
    assert {:ok, view, _html} = live(conn, ~p"/session/#{started.id}")
    attrs = %{"burpee_count_actual" => 4, "duration_sec_actual" => 20}
    tracking = %{"enabled" => false, "trust" => "disabled", "cadence_ms" => []}

    assert {:ok, completed} =
             Workouts.complete_session(Scope.for_user(user), started.id, attrs, :timed)

    render_hook(view, "save_session", %{
      "workout_session" => Map.put(attrs, "client_session_id", Ecto.UUID.generate()),
      "tracking" => tracking
    })

    assert_reply(view, %{status: "error"})

    render_hook(view, "save_session", %{
      "workout_session" =>
        Map.merge(attrs, %{"client_session_id" => token, "burpee_count_actual" => 9}),
      "tracking" => tracking
    })

    session_id = started.id
    assert_reply(view, %{status: "ok", session_id: ^session_id, redirect_to: "/"})
    assert Repo.get!(WorkoutSession, started.id) == completed
  end

  test "foreign, completed, and missing session IDs do not mount", %{conn: conn, user: user} do
    other_user = user_fixture()
    other_plan = plan_fixture(other_user)

    assert {:ok, foreign} =
             Workouts.start_plan(Scope.for_user(other_user), other_plan.id, Ecto.UUID.generate())

    own_plan = plan_fixture(user)

    assert {:ok, completed} =
             Workouts.start_plan(Scope.for_user(user), own_plan.id, Ecto.UUID.generate())

    assert {:ok, completed} =
             Workouts.complete_session(
               Scope.for_user(user),
               completed.id,
               %{"burpee_count_actual" => 1, "duration_sec_actual" => 1},
               :timed
             )

    for session_id <- [foreign.id, 2_147_483_647] do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/session/#{session_id}")
    end

    assert {:ok, view, _html} = live(conn, ~p"/session/#{completed.id}")

    assert has_element?(
             view,
             "#session-already-saved[phx-hook=SessionCompleted]" <>
               "[data-session-id='#{completed.id}']" <>
               "[data-content-hash='#{completed.content_hash}']" <>
               "[data-client-session-id='#{completed.client_session_id}']" <>
               "[data-redirect-to='/']"
           )

    refute has_element?(view, "#burpee-session")
    assert Repo.get!(WorkoutSession, completed.id) == completed
  end
end
