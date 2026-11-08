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

  test "a video finishes on the plan's finish screen and logs its count, length, mood, tags and note",
       %{conn: conn, user: user} do
    video = video_fixture(%{burpee_count: nil, duration_sec: 600})

    assert {:ok, started} =
             Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

    assert {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}/session/#{started.id}")
    refute has_element?(view, "#session-completion-review")

    render_click(view, "video_ended")

    assert has_element?(
             view,
             "#session-completion-review #session-completion-heading",
             video.name
           )

    refute has_element?(view, "#workout-video")
    assert has_element?(view, "#session-actual-reps[value='0']")
    assert has_element?(view, "#completion-reps-less[disabled]")

    view
    |> form("#session-completion-form", %{"workout_session" => %{"burpee_count_actual" => "36"}})
    |> render_change()

    view |> element("#completion-reps-more") |> render_click()
    assert has_element?(view, "#session-actual-reps[value='37']")

    view |> element("#session-completion-mood button[phx-value-mood='1']") |> render_click()

    assert has_element?(
             view,
             "#session-completion-mood button[phx-value-mood='1'][aria-pressed='true']"
           )

    view |> element("#session-completion-tags button[phx-value-tag='hot']") |> render_click()

    view
    |> form("#session-completion-form", %{
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
    assert completed.capture_mode == :logged
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

    assert has_element?(view, "#session-actual-reps[value='100']")
    assert has_element?(view, "#session-completion-review", "of 100")
    assert has_element?(view, "#session-completion-review", "20:00")
  end

  test "Abort while watching and the trash on the finish screen each ask in place, then delete",
       %{conn: conn, user: user} do
    video = video_fixture(%{burpee_count: 10, duration_sec: 600})

    for {finished?, button, armed} <- [
          {false, "#video-abort-btn", "abort"},
          {true, "#session-discard-btn", "delete"}
        ] do
      assert {:ok, started} =
               Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

      assert {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}/session/#{started.id}")
      if finished?, do: render_click(view, "video_ended")

      # The first tap asks; a tap anywhere else lets go.
      view |> element(button) |> render_click()
      assert has_element?(view, "#video-session[data-armed='#{armed}']")
      assert has_element?(view, "#{button}[aria-pressed='true']")
      render_click(view, "disarm")
      refute has_element?(view, "#video-session[data-armed]")
      assert Repo.get(WorkoutSession, started.id)

      # Asked again, the second tap deletes.
      view |> element(button) |> render_click()
      view |> element(button) |> render_click()
      assert_redirect(view, ~p"/")
      refute Repo.get(WorkoutSession, started.id)
    end
  end

  test "watching offers Finish early and Abort as icons; Finish early asks, then logs the time reached",
       %{conn: conn, user: user} do
    video = video_fixture(%{burpee_count: 100, duration_sec: 1200})

    assert {:ok, started} =
             Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

    assert {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}/session/#{started.id}")
    assert has_element?(view, "#video-finish-early[aria-label='Finish early']")
    assert has_element?(view, "#video-abort-btn[aria-label='Abort workout']")
    refute has_element?(view, "#video-session a[href='/']")

    # The first tap asks; the hook ends the video on the second.
    view |> element("#video-finish-early") |> render_click()
    assert has_element?(view, "#video-session[data-armed='finish']")

    render_click(view, "video_ended", %{"watched_sec" => 312})
    refute has_element?(view, "#video-session[data-armed]")
    assert has_element?(view, "#session-completion-review", "5:12")

    view
    |> form("#session-completion-form", %{"workout_session" => %{"burpee_count_actual" => "40"}})
    |> render_submit()

    assert Repo.get!(WorkoutSession, started.id).duration_sec_actual == 312
  end

  test "with the device's camera on, the camera counts the reps and the session is tracked",
       %{conn: conn, user: user} do
    video = video_fixture(%{burpee_count: 100, duration_sec: 1200})
    route = fn session -> ~p"/videos/#{video.id}/session/#{session.id}" end

    assert {:ok, started} =
             Workouts.start_video(Scope.for_user(user), video.id, Ecto.UUID.generate())

    {:ok, without, _html} = live(conn, route.(started))
    refute has_element?(without, "#pose-tracker")

    camera = %{"start_choices" => %{"camera" => true, "warmup" => true}}
    {:ok, view, _html} = conn |> put_connect_params(camera) |> live(route.(started))

    assert has_element?(
             view,
             "#video-session[data-camera='true'] #pose-tracker[phx-hook='PoseTracker']"
           )

    # The camera's setup is a dialog over the page, named by its status, its chips labelled
    # and a way back Home, as the plan session's camera setup.
    assert has_element?(
             view,
             "#pose-tracker[data-stage='setup'][role=dialog][aria-modal=true][aria-labelledby='video-camera-status']"
           )

    assert has_element?(view, "#video-camera-status[role=status][aria-live=polite]")

    for label <- ["Play the video", "Continue without camera", "Try the camera again"] do
      assert has_element?(view, "#pose-tracker button[aria-label='#{label}']")
    end

    assert has_element?(view, "#video-camera-back[href='/'][aria-label='Back to Home']")

    render_click(view, "video_ended", %{"watched_sec" => 1200, "counted_reps" => 97})
    assert has_element?(view, "#session-actual-reps[value='97']")
    assert has_element?(view, "#session-count-source", "Counted by camera")
    view |> element("#completion-reps-more") |> render_click()
    assert has_element?(view, "#session-count-source", "Camera counted 97")

    view
    |> form("#session-completion-form", %{"workout_session" => %{"burpee_count_actual" => "98"}})
    |> render_submit()

    completed = Repo.get!(WorkoutSession, started.id)
    assert completed.burpee_count_actual == 98
    assert completed.capture_mode == :tracked
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
      assert has_element?(view, "#session-completion-form")
      assert Repo.get!(WorkoutSession, started.id).state == :started
    end

    for {event, params} <- [
          {"set_mood", %{"mood" => "7"}},
          {"toggle_tag", %{"tag" => "unknown"}},
          {"step_reps", %{"step" => "50"}},
          {"video_ended", %{"counted_reps" => -4}}
        ] do
      render_hook(view, event, params)
      assert has_element?(view, "#session-actual-reps[value='10']")
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
    |> form("#session-completion-form", %{"workout_session" => %{"burpee_count_actual" => "10"}})
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

    plan = plan_fixture(user)

    assert {:ok, plan_session} =
             Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

    before_count = Repo.aggregate(WorkoutSession, :count)

    for path <- [
          ~p"/videos/#{video.id}/session/#{foreign.id}",
          ~p"/videos/#{other_video.id}/session/#{mismatch.id}",
          ~p"/videos/#{video.id}/session/#{plan_session.id}",
          ~p"/videos/#{video.id}/session/#{completed.id}",
          ~p"/videos/#{video.id}/session/2147483647"
        ] do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, path)
    end

    assert Repo.aggregate(WorkoutSession, :count) == before_count
  end

  def handle_workout_session_update(_event, _measurements, metadata, %{parent: parent}) do
    if is_binary(metadata.query) and
         String.starts_with?(metadata.query, "UPDATE \"workout_sessions\"") do
      send(parent, {:workout_session_update, metadata.query})
    end
  end
end
