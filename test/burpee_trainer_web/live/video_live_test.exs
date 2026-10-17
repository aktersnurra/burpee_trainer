defmodule BurpeeTrainerWeb.VideoLiveTest do
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

  test "session route and reconnect load the immutable video snapshot without inserting", %{
    conn: conn,
    user: user
  } do
    video = video_fixture(%{burpee_count: nil, duration_sec: 600})

    assert {:ok, session} =
             Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

    assert session.video_snapshot == %{
             "name" => video.name,
             "filename" => video.filename,
             "type" => Atom.to_string(video.burpee_type),
             "duration" => 600,
             "count" => nil,
             "format" => Atom.to_string(video.format)
           }

    Ecto.Changeset.change(video, %{name: "Live row changed", available: false}) |> Repo.update!()

    route = ~p"/videos/#{video.id}/session/#{session.id}"
    assert {:ok, view, _html} = live(conn, route)
    assert Repo.aggregate(WorkoutSession, :count) == 1

    assert has_element?(
             view,
             "#video-session[data-session-id='#{session.id}'][data-client-session-id='#{session.client_session_id}'][data-content-hash='#{session.content_hash}']"
           )

    assert has_element?(view, "#workout-video")
    assert has_element?(view, "#video-session", video.name)
    refute has_element?(view, "#video-session", "Live row changed")
    assert {:ok, _reconnected, _html} = live(conn, route)
    assert Repo.aggregate(WorkoutSession, :count) == 1
  end

  test "finishing a video logs its count, the video's length, mood, tags and a note", %{
    conn: conn,
    user: user
  } do
    video = video_fixture(%{burpee_count: nil, duration_sec: 600})

    assert {:ok, started} =
             Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

    assert {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}/session/#{started.id}")
    refute has_element?(view, "#video-completion")

    render_click(view, "video_ended")

    assert has_element?(view, "#video-completion h1", "Workout complete")
    refute has_element?(view, "#workout-video")
    assert has_element?(view, "#video-actual-reps[value='0']")
    assert has_element?(view, "#video-reps-less[disabled]")

    view
    |> form("#video-log-form", %{"workout_session" => %{"burpee_count_actual" => "36"}})
    |> render_change()

    view |> element("#video-reps-more") |> render_click()
    assert has_element?(view, "#video-actual-reps[value='37']")

    view |> element("#video-completion-mood button[phx-value-mood='1']") |> render_click()

    assert has_element?(
             view,
             "#video-completion-mood button[phx-value-mood='1'][aria-pressed='true']"
           )

    view |> element("#video-completion-tags button[phx-value-tag='hot']") |> render_click()

    view
    |> form("#video-log-form", %{
      "workout_session" => %{"burpee_count_actual" => "37", "note_post" => "Strong finish"}
    })
    |> render_submit()

    assert_redirect(view, ~p"/")
    assert Repo.aggregate(WorkoutSession, :count) == 1
    completed = Repo.get!(WorkoutSession, started.id)
    assert completed.state == :completed
    assert completed.burpee_count_planned == nil
    assert completed.burpee_count_actual == 37
    assert completed.duration_sec_actual == 600
    assert completed.mood == 1
    assert completed.tags == "hot"
    assert completed.note_post == "Strong finish"
  end

  test "a video with a count starts the finish screen at it", %{conn: conn, user: user} do
    video = video_fixture(%{burpee_count: 100, duration_sec: 1200})

    assert {:ok, started} =
             Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

    assert {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}/session/#{started.id}")
    render_click(view, "video_ended")

    assert has_element?(view, "#video-actual-reps[value='100']")
    assert has_element?(view, "#video-completion", "of 100")
    assert has_element?(view, "#video-completion", "20:00")
  end

  test "the workout can be discarded while watching and from the finish screen", %{
    conn: conn,
    user: user
  } do
    video = video_fixture(%{burpee_count: 10, duration_sec: 600})

    for finished? <- [false, true] do
      assert {:ok, started} =
               Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

      assert {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}/session/#{started.id}")
      if finished?, do: render_click(view, "video_ended")

      refute has_element?(view, "#video-discard-confirm")
      view |> element("#video-discard-btn") |> render_click()
      verb = if finished?, do: "Discard", else: "Abort"
      assert has_element?(view, "#video-discard-confirm", "#{verb} this workout?")
      refute has_element?(view, "#video-discard-btn")

      view |> element("#video-discard-keep") |> render_click()
      refute has_element?(view, "#video-discard-confirm")
      assert has_element?(view, "#video-discard-btn")

      view |> element("#video-discard-btn") |> render_click()
      view |> element("#video-discard-yes") |> render_click()

      assert_redirect(view, ~p"/")
      refute Repo.get(WorkoutSession, started.id)
    end
  end

  test "watching offers Finish early or Abort, and Finish early logs the time reached", %{
    conn: conn,
    user: user
  } do
    video = video_fixture(%{burpee_count: 100, duration_sec: 1200})

    assert {:ok, started} =
             Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

    assert {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}/session/#{started.id}")
    assert has_element?(view, "#video-finish-early", "Finish early")
    assert has_element?(view, "#video-discard-btn", "Abort")
    refute has_element?(view, "#video-session a[href='/']")

    render_click(view, "video_ended", %{"watched_sec" => 312})
    assert has_element?(view, "#video-completion", "5:12")

    view
    |> form("#video-log-form", %{"workout_session" => %{"burpee_count_actual" => "40"}})
    |> render_submit()

    assert Repo.get!(WorkoutSession, started.id).duration_sec_actual == 312
  end

  test "forged completion fields never complete the session", %{conn: conn, user: user} do
    video = video_fixture(%{burpee_count: 10, duration_sec: 600})

    assert {:ok, started} =
             Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

    assert {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}/session/#{started.id}")
    render_click(view, "video_ended")

    valid = %{"burpee_count_actual" => "10", "note_post" => "after"}

    for {field, forged} <- [
          {"burpee_count_actual", %{}},
          {"burpee_count_actual", "-3"},
          {"burpee_count_actual", "ten"},
          {"note_post", 123},
          {"note_post", String.duplicate("x", 501)}
        ] do
      render_hook(view, "save", %{"workout_session" => Map.put(valid, field, forged)})
      assert has_element?(view, "#video-log-form")
      assert Repo.get!(WorkoutSession, started.id).state == :started
    end

    for {event, params} <- [
          {"set_mood", %{"mood" => "7"}},
          {"toggle_tag", %{"tag" => "unknown"}},
          {"step_reps", %{"step" => "50"}}
        ] do
      render_hook(view, event, params)
      assert has_element?(view, "#video-actual-reps[value='10']")
    end
  end

  test "goal-achieving completion updates the session once and attributes the goal", %{
    conn: conn,
    user: user
  } do
    video = video_fixture(%{burpee_count: 10, duration_sec: 1200})
    goal = goal_fixture(user, %{"burpee_count_target" => 10, "burpee_count_baseline" => 5})

    assert {:ok, started} =
             Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

    assert {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}/session/#{started.id}")
    render_click(view, "video_ended")

    telemetry_id = "video-goal-completion-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      telemetry_id,
      [:burpee_trainer, :repo, :query],
      &__MODULE__.handle_workout_session_update/4,
      %{parent: self()}
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    view
    |> form("#video-log-form", %{"workout_session" => %{"burpee_count_actual" => "10"}})
    |> render_submit()

    assert_redirect(view, ~p"/")
    assert_receive {:workout_session_update, query}
    assert query =~ "UPDATE \"workout_sessions\""
    refute_receive {:workout_session_update, _second_query}

    completed = Repo.get!(WorkoutSession, started.id)
    assert completed.state == :completed
    assert completed.goal_id == goal.id
    assert Repo.get!(BurpeeTrainer.Goals.Goal, goal.id).status == :achieved
    assert Repo.aggregate(WorkoutSession, :count) == 1
  end

  test "missing, foreign, mismatched, and completed session routes do not insert", %{
    conn: conn,
    user: user
  } do
    video = video_fixture()
    other_video = video_fixture()
    other_user = user_fixture()

    assert {:ok, foreign} =
             Workouts.start_video(Scope.for_user(other_user), video.id, Ecto.UUID.generate())

    assert {:ok, mismatch} =
             Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

    assert {:ok, completed} =
             Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

    assert {:ok, completed} =
             Workouts.complete_session(
               Scope.for_user(user),
               completed.id,
               %{"burpee_count_actual" => 1, "duration_sec_actual" => 1},
               :logged
             )

    before_count = Repo.aggregate(WorkoutSession, :count)

    for path <- [
          ~p"/videos/#{video.id}/session/#{foreign.id}",
          ~p"/videos/#{other_video.id}/session/#{mismatch.id}",
          ~p"/videos/#{video.id}/session/#{completed.id}",
          ~p"/videos/#{video.id}/session/2147483647"
        ] do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, path)
    end

    assert Repo.aggregate(WorkoutSession, :count) == before_count
  end

  test "completion rejects ownership and source mismatches in socket state", %{user: user} do
    plan = plan_fixture(user)

    assert {:ok, plan_session} =
             Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

    foreign_user = user_fixture()
    video = video_fixture()

    assert {:ok, foreign_video_session} =
             Workouts.start_video(Scope.for_user(foreign_user), video.id, Ecto.UUID.generate())

    for session <- [plan_session, foreign_video_session],
        event <- ["validate", "save", "discard"] do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          current_scope: Scope.for_user(user),
          workout_session: session,
          video: %{duration_sec: 120},
          mood: nil,
          tags: [],
          reps: 10,
          note: ""
        }
      }

      assert {:noreply, ^socket} =
               BurpeeTrainerWeb.VideoLive.Show.handle_event(
                 event,
                 %{"workout_session" => %{"burpee_count_actual" => "10"}},
                 socket
               )
    end

    assert Repo.get!(WorkoutSession, plan_session.id).state == :started
    assert Repo.get!(WorkoutSession, foreign_video_session.id).state == :started
  end

  def handle_workout_session_update(_event, _measurements, metadata, %{parent: parent}) do
    if is_binary(metadata.query) and
         String.starts_with?(metadata.query, "UPDATE \"workout_sessions\"") do
      send(parent, {:workout_session_update, metadata.query})
    end
  end
end
