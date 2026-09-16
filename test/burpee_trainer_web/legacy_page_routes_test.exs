defmodule BurpeeTrainerWeb.LegacyPageRoutesTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.Workouts

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "obsolete workout and video pages return to Home", %{conn: conn} do
    for path <- ["/workouts", "/workouts/new", "/workouts/drafts/42", "/videos", "/videos/42"] do
      assert conn |> get(path) |> redirected_to() == ~p"/"
    end
  end

  test "video sessions retain Home and History without catalog navigation", %{
    conn: conn,
    user: user
  } do
    video = video_fixture()
    assert {:ok, session} = Workouts.start_video(user, video.id, Ecto.UUID.generate())
    {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}/session/#{session.id}")

    assert has_element?(view, "#desktop-home-nav")
    assert has_element?(view, "#mobile-history-nav")
    refute has_element?(view, "#desktop-library-nav")
    refute has_element?(view, "#desktop-videos-nav")
    refute has_element?(view, "#mobile-library-nav")
    refute has_element?(view, "#mobile-videos-nav")
  end
end
