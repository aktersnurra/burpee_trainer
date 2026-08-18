defmodule BurpeeTrainerWeb.AppFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "Library Start creates one exact immutable session before the runner mounts", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user, %{"name" => "Cross-screen snapshot"})
    {:ok, library, _html} = live(conn, ~p"/workouts")

    library |> element("#start-workout-#{plan.id}") |> render_click()
    started = Workouts.current_started_session(user)
    assert_redirect(library, ~p"/session/#{started.id}")
    assert Repo.aggregate(WorkoutSession, :count) == 1

    {:ok, runner, _html} = live(conn, ~p"/session/#{started.id}")

    assert has_element?(
             runner,
             "#burpee-session[data-session-id='#{started.id}'][data-content-hash='#{started.content_hash}'][data-source-kind='plan'][data-session-program]"
           )

    for id <- ~w[
      session-capture-choice
      session-camera-status
      session-camera-setup
      session-warmup-choice
      session-workout-ready
      session-runner-client
      session-completion-review
    ] do
      assert has_element?(runner, "##{id}[data-session-panel]")
    end

    assert Repo.aggregate(WorkoutSession, :count) == 1
  end

  test "Video index, detail, direct session mount, and reconnect never create extra sessions", %{
    conn: conn,
    user: user
  } do
    video = video_fixture(%{burpee_count: nil})

    {:ok, index, _html} = live(conn, ~p"/videos")
    assert has_element?(index, "#video-card-#{video.id}")
    assert Repo.aggregate(WorkoutSession, :count) == 0

    {:ok, detail, _html} = live(conn, ~p"/videos/#{video.id}")
    assert Repo.aggregate(WorkoutSession, :count) == 0

    detail |> element("#video-start-action") |> render_click()
    started = Workouts.current_started_session(user)
    assert_redirect(detail, ~p"/videos/#{video.id}/session/#{started.id}")
    assert Repo.aggregate(WorkoutSession, :count) == 1

    {:ok, first_mount, _html} = live(conn, ~p"/videos/#{video.id}/session/#{started.id}")
    assert has_element?(first_mount, "#video-session[data-session-id='#{started.id}']")
    assert Repo.aggregate(WorkoutSession, :count) == 1

    {:ok, reconnect, _html} = live(conn, ~p"/videos/#{video.id}/session/#{started.id}")
    assert has_element?(reconnect, "#video-session[data-session-id='#{started.id}']")
    assert Repo.aggregate(WorkoutSession, :count) == 1
  end

  test "Home fallback remains startable when no generated candidate is attached", %{
    conn: conn,
    user: user
  } do
    {:ok, slot} = BurpeeTrainer.Coach.Policy.required_slot(user, DateTime.utc_now(:second))

    assert {:ok, recommendation} =
             Workouts.ensure_recommendation(user, %{
               slot_key: slot.slot_key,
               slot_date: slot.slot_date,
               rationale: "Fallback remains ready."
             })

    {:ok, home, _html} = live(conn, ~p"/")

    assert has_element?(
             home,
             "#start-recommended-workout[phx-value-plan-id='#{recommendation.selected_workout_plan_id}']"
           )

    home |> element("#start-recommended-workout") |> render_click()
    started = Workouts.current_started_session(user)
    assert_redirect(home, ~p"/session/#{started.id}")
  end
end
