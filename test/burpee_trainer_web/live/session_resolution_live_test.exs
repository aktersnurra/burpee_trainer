defmodule BurpeeTrainerWeb.SessionResolutionLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "owner sees the unresolved session form and source-derived metadata", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user, %{"name" => "Recovery plan"})
    session = lifecycle_session(user, plan)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/resolve")

    assert has_element?(
             view,
             "#session-resolution[phx-hook='SessionRecoveryHook'][data-client-session-id='#{session.client_session_id}'][data-session-status='running']"
           )

    assert has_element?(view, "#session-resolution-status", "must be logged or discarded")
    assert has_element?(view, "#session-resolution-form")
    assert has_element?(view, "#session-resolution-abort[phx-click='abort']")
    assert has_element?(view, "#session-resolution-source", "Recovery plan")
    assert has_element?(view, "#session-resolution-planned-count", "30")
    assert has_element?(view, "#session-resolution-planned-duration", "20:00")
  end

  test "reconciles only the mounted running session UUID", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    session = lifecycle_session(user, plan)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/resolve")

    render_hook(view, "reconcile_local_completion", %{})
    assert Repo.get!(WorkoutSession, session.id).status == :running

    render_hook(view, "reconcile_local_completion", %{
      "client_session_id" => Ecto.UUID.generate()
    })

    assert Repo.get!(WorkoutSession, session.id).status == :running

    render_hook(view, "reconcile_local_completion", %{
      "client_session_id" => session.client_session_id
    })

    assert Repo.get!(WorkoutSession, session.id).status == :report_pending
  end

  test "manual report returns the browser recovery acknowledgement without navigating", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user)
    session = lifecycle_session(user, plan, pending?: true)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/resolve")

    render_hook(view, "report", %{
      "workout_session" => %{
        "burpee_count_actual" => "17",
        "duration_sec_actual" => "95",
        "mood" => "1",
        "tags" => "great_energy",
        "note_post" => "Recovered manually"
      }
    })

    session_id = session.id
    client_session_id = session.client_session_id

    assert_reply(view, %{
      status: "ok",
      session_id: ^session_id,
      client_session_id: ^client_session_id,
      redirect_to: "/stats"
    })

    refute_redirected(view)
  end

  test "manual reporting updates the exact running or pending row without another row", %{
    conn: conn,
    user: user
  } do
    for pending? <- [false, true] do
      plan = plan_fixture(user)
      session = lifecycle_session(user, plan, pending?: pending?)
      session_count = Repo.aggregate(WorkoutSession, :count, :id)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/resolve")

      render_hook(view, "report", %{
        "workout_session" => %{
          "burpee_count_actual" => "17",
          "duration_sec_actual" => "95",
          "mood" => "1",
          "tags" => "great_energy",
          "note_post" => "Recovered manually"
        }
      })

      assert_reply(view, %{status: "ok", redirect_to: "/stats"})

      reported = Repo.get!(WorkoutSession, session.id)
      assert reported.status == :reported
      assert reported.burpee_count_actual == 17
      assert reported.duration_sec_actual == 95
      assert reported.client_session_id == session.client_session_id
      assert Repo.aggregate(WorkoutSession, :count, :id) == session_count
    end
  end

  test "abort updates the exact unresolved row", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    session = lifecycle_session(user, plan)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/resolve")

    view |> element("#session-resolution-abort") |> render_click()

    assert_redirect(view, ~p"/workouts")
    assert Repo.get!(WorkoutSession, session.id).status == :aborted
    assert Repo.aggregate(WorkoutSession, :count, :id) == 1
  end

  test "malformed, absent, foreign, and terminal sessions redirect to stats", %{
    conn: conn,
    user: user
  } do
    assert {:error, {:live_redirect, %{to: "/stats"}}} = live(conn, "/sessions/not-an-id/resolve")
    assert {:error, {:live_redirect, %{to: "/stats"}}} = live(conn, "/sessions/999999/resolve")

    other_user = user_fixture()
    foreign_plan = plan_fixture(other_user)
    foreign = lifecycle_session(other_user, foreign_plan)

    assert {:error, {:live_redirect, %{to: "/stats"}}} =
             live(conn, ~p"/sessions/#{foreign.id}/resolve")

    plan = plan_fixture(user)
    reported = lifecycle_session(user, plan)

    assert {:ok, _, _} =
             Workouts.report_session(user, reported.client_session_id, report_attrs(), %{})

    assert {:error, {:live_redirect, %{to: "/stats"}}} =
             live(conn, ~p"/sessions/#{reported.id}/resolve")

    aborted = lifecycle_session(user, plan)
    assert {:ok, _} = Workouts.abort_session(user, aborted.client_session_id)

    assert {:error, {:live_redirect, %{to: "/stats"}}} =
             live(conn, ~p"/sessions/#{aborted.id}/resolve")
  end

  test "changeset errors keep the user on the form", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    session = lifecycle_session(user, plan)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/resolve")

    render_hook(view, "report", %{
      "workout_session" => %{"burpee_count_actual" => "", "duration_sec_actual" => ""}
    })

    assert_reply(view, %{status: "error"})
    assert has_element?(view, "#session-resolution-form")
    assert has_element?(view, "#session-resolution-errors[role='alert']", "can't be blank")
    assert Repo.get!(WorkoutSession, session.id).status == :running
  end

  defp lifecycle_session(user, plan, opts \\ []) do
    assert {:ok, session} = Workouts.begin_plan_session(user, plan, Ecto.UUID.generate())

    if Keyword.get(opts, :pending?, false) do
      assert {:ok, session} = Workouts.mark_report_pending(user, session.client_session_id)
      session
    else
      session
    end
  end

  defp report_attrs do
    %{"burpee_count_actual" => 12, "duration_sec_actual" => 60}
  end
end
