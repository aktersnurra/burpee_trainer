defmodule BurpeeTrainerWeb.VideoRoutesTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.Workouts

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "removed pages are not routed", %{conn: conn} do
    for path <-
          ~w[/workouts /workouts/new /workouts/drafts/1 /videos /videos/1 /stats /stats/sessions/1] do
      assert get(conn, path).status == 404
    end
  end

  test "a video session, like a plan session, shows no app navigation", %{
    conn: conn,
    user: user
  } do
    video = video_fixture()

    assert {:ok, session} =
             Workouts.start_video(
               BurpeeTrainer.Accounts.Scope.for_user(user),
               video.id,
               Ecto.UUID.generate()
             )

    {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}/session/#{session.id}")

    refute has_element?(view, "#desktop-home-nav")
    refute has_element?(view, "#mobile-history-nav")
    refute has_element?(view, "#desktop-library-nav")
    refute has_element?(view, "#desktop-videos-nav")
    refute has_element?(view, "#mobile-library-nav")
    refute has_element?(view, "#mobile-videos-nav")
  end
end
