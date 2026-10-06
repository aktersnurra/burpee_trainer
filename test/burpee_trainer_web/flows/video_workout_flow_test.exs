defmodule BurpeeTrainerWeb.Flows.VideoWorkoutFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts.WorkoutSession

  test "Home video chooser starts, logs, and lists a video session in History", %{conn: conn} do
    user = user_fixture()
    video = video_fixture(%{burpee_count: 10, duration_sec: 120})
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    render_click(view, "tab", %{"tab" => "videos"})

    {:error, {:live_redirect, %{to: path}}} =
      view |> element("#home-alternative-video-#{video.id}-select") |> render_click()

    assert path =~ "/videos/#{video.id}/session/"
    [_, id] = Regex.run(~r{/session/(\d+)$}, path)
    {:ok, session, _} = live(init_test_session(conn, %{user_id: user.id}), path)
    render_click(session, "video_ended")

    session
    |> form("#video-log-form", %{
      "workout_session" => %{"burpee_count_actual" => "10", "duration_min" => "2"}
    })
    |> render_submit()

    completed = Repo.get!(WorkoutSession, String.to_integer(id))
    assert completed.state == :completed
    {:ok, history, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/history")
    assert has_element?(history, "#home-history-session-#{completed.id}")
  end
end
