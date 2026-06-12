defmodule BurpeeTrainerWeb.PageControllerTest do
  use BurpeeTrainerWeb.ConnCase

  import BurpeeTrainer.Fixtures

  test "GET / redirects unauthenticated users to /login", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/login"
  end

  test "GET / renders the dashboard for an authenticated user", %{conn: conn} do
    user = user_fixture(%{"username" => "alice"})
    conn = conn |> init_test_session(%{user_id: user.id}) |> get(~p"/")
    html = html_response(conn, 200)
    assert html =~ "Home"
    assert html =~ "Workouts"
  end

  test "GET / uses session surface visual system", %{conn: conn} do
    user = user_fixture(%{"username" => "home_surface_user"})
    conn = conn |> init_test_session(%{user_id: user.id}) |> get(~p"/")
    html = html_response(conn, 200)

    assert html =~ "session-surface"
    assert html =~ "text-[var(--session-ink)]"
    assert html =~ ~s(id="home-page")
    assert html =~ ~s(id="home-status-strip")
  end

  test "GET / puts the primary workout before secondary suggestions", %{conn: conn} do
    user = user_fixture(%{"username" => "home_order_user"})
    plan = plan_fixture(user, %{"name" => "Resume Plan"})

    session_from_plan_fixture(user, plan, %{
      "burpee_count_actual" => 30,
      "duration_sec_actual" => 180
    })

    for _ <- 1..4 do
      free_form_session_fixture(user, %{
        "burpee_count_actual" => 30,
        "duration_sec_actual" => 180
      })
    end

    goal_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_target" => 90,
      "duration_sec_target" => 1200,
      "burpee_count_baseline" => 30,
      "duration_sec_baseline" => 1200
    })

    conn = conn |> init_test_session(%{user_id: user.id}) |> get(~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(id="home-primary-workout")
    assert html =~ ~s(data-home-weekly-split)

    {primary_index, _} = :binary.match(html, ~s(id="home-primary-workout"))
    {split_index, _} = :binary.match(html, ~s(data-home-weekly-split))

    assert primary_index < split_index
  end

  test "GET / renders a quiet weekly status strip", %{conn: conn} do
    user = user_fixture(%{"username" => "home_rhythm_user"})

    conn = conn |> init_test_session(%{user_id: user.id}) |> get(~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(id="home-status-strip")
    assert html =~ ~s(/ 80 min this week)
  end

  test "GET / presents a primary start action when a plan exists", %{conn: conn} do
    user = user_fixture(%{"username" => "home_primary_action_user"})
    plan = plan_fixture(user, %{"name" => "Primary Plan"})

    session_from_plan_fixture(user, plan, %{
      "burpee_count_actual" => 30,
      "duration_sec_actual" => 180
    })

    conn = conn |> init_test_session(%{user_id: user.id}) |> get(~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(id="home-start-workout")
    assert html =~ ~s(href="/session/#{plan.id}")
  end
end
