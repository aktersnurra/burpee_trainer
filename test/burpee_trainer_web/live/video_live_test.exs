defmodule BurpeeTrainerWeb.VideoLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "renders an enabled durable start gate before the video can be played", %{
    conn: conn,
    user: user
  } do
    video = video_fixture()
    {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}")

    assert has_element?(view, "#video-start-workout:not([disabled])")
    assert has_element?(view, "#workout-video[phx-hook='VideoHook']")
    assert has_element?(view, "#video-lifecycle-status[role='status'][aria-live='polite']")
    assert has_element?(view, "#video-report-retry[hidden]")
    refute has_element?(view, "#video-log-form")
    assert Workouts.list_sessions(user) == []
  end

  test "redirects to the resolver before mounting a video when another workout is unresolved", %{
    conn: conn,
    user: user
  } do
    unresolved_video = video_fixture()

    assert {:ok, unresolved} =
             Workouts.begin_video_session(user, unresolved_video, Ecto.UUID.generate())

    next_video = video_fixture()
    expected_path = "/sessions/#{unresolved.id}/resolve"

    assert {:error, {:live_redirect, %{to: ^expected_path}}} =
             live(conn, ~p"/videos/#{next_video.id}")
  end

  test "video lifecycle uses one UUID, exposes the report form only after pending, and reports its row",
       %{
         user: user
       } do
    video = video_fixture(%{burpee_type: :navy_seal, burpee_count: 12, duration_sec: 75})
    client_session_id = Ecto.UUID.generate()
    socket = video_socket(user, video)

    assert {:reply,
            %{status: "ok", client_session_id: ^client_session_id, lifecycle_status: "running"},
            socket} =
             BurpeeTrainerWeb.VideoLive.Show.handle_event(
               "begin_video_session",
               %{"client_session_id" => client_session_id},
               socket
             )

    assert {:reply, %{status: "ok", lifecycle_status: "report_pending"}, socket} =
             BurpeeTrainerWeb.VideoLive.Show.handle_event(
               "mark_video_report_pending",
               %{"client_session_id" => client_session_id},
               socket
             )

    assert socket.assigns.log_visible
    assert socket.assigns.client_session_id == client_session_id

    attrs = %{
      "burpee_count_actual" => "11",
      "duration_min" => "2",
      "note_post" => "Completed the video",
      "mood" => "0",
      "tags" => ""
    }

    assert {:noreply, _socket} =
             BurpeeTrainerWeb.VideoLive.Show.handle_event(
               "save",
               %{"workout_session" => attrs},
               socket
             )

    [session] = Workouts.list_sessions(user)
    assert session.client_session_id == client_session_id
    assert session.source == :video
    assert session.status == :reported
    assert session.capture_mode == :logged
    assert session.burpee_count_actual == 11
    assert session.duration_sec_actual == 120

    assert {:ok, ^session, :existing} =
             Workouts.report_session(user, client_session_id, report_attrs(attrs), %{
               "enabled" => false
             })

    assert [_only_session] = Workouts.list_sessions(user)
  end

  test "begin returns a resolver route instead of crashing on a concurrent unresolved session", %{
    user: user
  } do
    unresolved_video = video_fixture()

    assert {:ok, unresolved} =
             Workouts.begin_video_session(user, unresolved_video, Ecto.UUID.generate())

    socket = video_socket(user, video_fixture())

    assert {:reply,
            %{
              status: "error",
              reason: "unresolved_session",
              retryable: true,
              session_id: unresolved_id,
              resolve_to: resolve_to
            }, ^socket} =
             BurpeeTrainerWeb.VideoLive.Show.handle_event(
               "begin_video_session",
               %{"client_session_id" => Ecto.UUID.generate()},
               socket
             )

    assert unresolved_id == unresolved.id
    assert resolve_to == "/sessions/#{unresolved.id}/resolve"
  end

  defp video_socket(user, video) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        video: video,
        client_session_id: nil,
        log_visible: false,
        mood: 0,
        log_tags: []
      }
    }
  end

  defp report_attrs(attrs) do
    %{
      "burpee_count_actual" => attrs["burpee_count_actual"],
      "duration_sec_actual" => "120",
      "note_post" => attrs["note_post"],
      "mood" => 0,
      "tags" => ""
    }
  end
end
