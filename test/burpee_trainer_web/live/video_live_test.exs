defmodule BurpeeTrainerWeb.VideoLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.{Goals, Repo, Workouts}
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
    assert {:ok, session} = Workouts.start_video(user, video.id, Ecto.UUID.generate())

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

  test "video completion updates the same nil-count session with confirmed actual reps", %{
    conn: conn,
    user: user
  } do
    video = video_fixture(%{burpee_count: nil, duration_sec: 600})
    assert {:ok, started} = Workouts.start_video(user, video.id, Ecto.UUID.generate())
    assert {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}/session/#{started.id}")

    render_click(view, "video_ended")

    view
    |> form("#video-log-form", %{
      "workout_session" => %{
        "burpee_count_actual" => "37",
        "duration_min" => "10",
        "context_low_energy" => "false",
        "context_high_energy" => "true",
        "context_heat_affected" => "false",
        "primary_limiter" => "breathing",
        "preference_feedback" => "choose_again"
      }
    })
    |> render_submit()

    assert_redirect(view, ~p"/")
    assert Repo.aggregate(WorkoutSession, :count) == 1
    completed = Repo.get!(WorkoutSession, started.id)
    assert completed.state == :completed
    assert completed.id == started.id
    assert completed.burpee_count_planned == nil
    assert completed.burpee_count_actual == 37
    assert completed.duration_sec_actual == 600
    assert completed.context_high_energy
    assert completed.primary_limiter == :breathing
    assert completed.preference_feedback == :choose_again
  end

  test "forged completion fields never complete the session", %{conn: conn, user: user} do
    video = video_fixture(%{burpee_count: 10, duration_sec: 600})
    assert {:ok, started} = Workouts.start_video(user, video.id, Ecto.UUID.generate())
    assert {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}/session/#{started.id}")
    render_click(view, "video_ended")

    valid = %{
      "burpee_count_actual" => "10",
      "duration_min" => "10",
      "note_pre" => "before",
      "note_post" => "after",
      "context_low_energy" => "false",
      "context_high_energy" => "false",
      "context_heat_affected" => "false",
      "primary_limiter" => "legs",
      "preference_feedback" => "avoid"
    }

    for {field, forged} <- [
          {"burpee_count_actual", %{}},
          {"duration_min", []},
          {"note_pre", 123},
          {"note_post", true},
          {"context_low_energy", %{}},
          {"context_high_energy", []},
          {"context_heat_affected", 1},
          {"primary_limiter", true},
          {"preference_feedback", %{}},
          {"primary_limiter", "unknown"}
        ] do
      render_hook(view, "validate", %{"workout_session" => Map.put(valid, field, forged)})
      assert has_element?(view, "#video-log-form")
      assert Repo.get!(WorkoutSession, started.id).state == :started
    end

    render_hook(view, "save", %{
      "workout_session" => Map.put(valid, "duration_min", %{"minutes" => 10})
    })

    assert has_element?(view, "#video-log-form")
    assert Repo.get!(WorkoutSession, started.id).state == :started
  end

  test "goal-achieving completion updates the session once and attributes the goal", %{
    conn: conn,
    user: user
  } do
    video = video_fixture(%{burpee_count: 10, duration_sec: 1200})
    goal = goal_fixture(user, %{"burpee_count_target" => 10, "burpee_count_baseline" => 5})
    assert {:ok, started} = Workouts.start_video(user, video.id, Ecto.UUID.generate())
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
    |> form("#video-log-form", %{
      "workout_session" => %{"burpee_count_actual" => "10", "duration_min" => "20"}
    })
    |> render_submit()

    assert_redirect(view, ~p"/")
    assert_receive {:workout_session_update, query}
    assert query =~ "UPDATE \"workout_sessions\""
    refute_receive {:workout_session_update, _second_query}

    completed = Repo.get!(WorkoutSession, started.id)
    assert completed.state == :completed
    assert completed.goal_id == goal.id
    assert Goals.get_goal!(user, goal.id).status == :achieved
    assert Repo.aggregate(WorkoutSession, :count) == 1
  end

  test "missing, foreign, mismatched, and completed session routes do not insert", %{
    conn: conn,
    user: user
  } do
    video = video_fixture()
    other_video = video_fixture()
    other_user = user_fixture()
    assert {:ok, foreign} = Workouts.start_video(other_user, video.id, Ecto.UUID.generate())
    assert {:ok, mismatch} = Workouts.start_video(user, video.id, Ecto.UUID.generate())
    assert {:ok, completed} = Workouts.start_video(user, video.id, Ecto.UUID.generate())

    assert {:ok, completed} =
             Workouts.complete_session(
               user,
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
    assert {:ok, plan_session} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())
    foreign_user = user_fixture()
    video = video_fixture()

    assert {:ok, foreign_video_session} =
             Workouts.start_video(foreign_user, video.id, Ecto.UUID.generate())

    for session <- [plan_session, foreign_video_session], event <- ["validate", "save"] do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          current_user: user,
          workout_session: session,
          mood: 0,
          log_tags: [],
          duration_min: "2"
        }
      }

      assert {:noreply, ^socket} =
               BurpeeTrainerWeb.VideoLive.Show.handle_event(
                 event,
                 %{"workout_session" => %{"burpee_count_actual" => "10", "duration_min" => "2"}},
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
