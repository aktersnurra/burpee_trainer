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
    assert html =~ ~s(id="home-coach-card")
    assert html =~ ~s(id="home-week-rhythm")
  end

  test "GET / puts the coach card before secondary suggestions", %{conn: conn} do
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

    conn = conn |> init_test_session(%{user_id: user.id}) |> get(~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(id="home-coach-card")
    assert html =~ ~s(data-home-coach-suggestion)

    {coach_card_index, _} = :binary.match(html, ~s(id="home-coach-card"))
    {suggestion_index, _} = :binary.match(html, ~s(data-home-coach-suggestion))

    assert coach_card_index < suggestion_index
  end

  test "GET / renders a seven segment weekly rhythm bar", %{conn: conn} do
    user = user_fixture(%{"username" => "home_rhythm_user"})

    conn = conn |> init_test_session(%{user_id: user.id}) |> get(~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(id="home-week-rhythm")
    assert html =~ ~s(/ 80 min)
    assert html =~ ~s(data-week-rhythm-segment)
    assert html =~ ~s(aria-label="Monday:)
    refute html =~ ~s(data-week-dot)
    assert length(Regex.scan(~r/data-week-rhythm-segment/, html)) == 7
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

    assert html =~ ~s(id="home-primary-action")
    assert html =~ ~s(href="/session/#{plan.id}")
    assert html =~ "What should I do now?"
  end
end
