defmodule BurpeeTrainerWeb.WorkoutsLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts

  setup %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, conn: conn, user: user}
  end

  describe "/workouts" do
    test "empty state renders when no plans or videos", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/workouts")
      assert html =~ "No workouts yet"
    end

    test "lists plans and videos together", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, _view, html} = live(conn, ~p"/workouts")

      assert html =~ "My Plan"
      assert html =~ "BDT Video"
    end

    test "Mine filter shows only plans", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()

      html = render(view)
      assert html =~ "My Plan"
      refute html =~ "BDT Video"
    end

    test "Videos filter shows only videos", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='videos']") |> render_click()

      html = render(view)
      refute html =~ "My Plan"
      assert html =~ "BDT Video"
    end

    test "clicking active source filter deselects it", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()
      view |> element("button[phx-value-source='mine']") |> render_click()

      html = render(view)
      assert html =~ "My Plan"
      assert html =~ "BDT Video"
    end

    test "type filter restricts list", %{conn: conn, user: user} do
      _six = plan_fixture(user, %{"name" => "Six plan", "burpee_type" => "six_count"})
      _seal = plan_fixture(user, %{"name" => "SEAL plan", "burpee_type" => "navy_seal"})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-burpee_type='six_count']") |> render_click()

      html = render(view)
      assert html =~ "Six plan"
      refute html =~ "SEAL plan"
    end

    test "Mine empty state shows when user has no plans", %{conn: conn} do
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()

      assert render(view) =~ "have not built any plans"
    end

    test "filter state reflected in URL", %{conn: conn, user: user} do
      _plan = plan_fixture(user)

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()

      assert_patch(view, "/workouts?source=mine")
    end

    test "plan card ⋯ menu shows edit, clone, delete options", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "My Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts")

      view |> element("button[phx-click='toggle_menu']") |> render_click()
      html = render(view)

      assert html =~ "/workouts/#{plan.id}/edit"
      assert html =~ "Clone"
      assert html =~ "Delete"
    end

    test "video card has no edit link", %{conn: conn} do
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})
      {:ok, _view, html} = live(conn, ~p"/workouts")

      refute html =~ ~r"/workouts/\d+/edit"
    end
  end
end
