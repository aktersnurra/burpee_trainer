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

  test "GET / puts the workout card before coach suggestions", %{conn: conn} do
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

    assert html =~ ~s(id="home-workout-card")
    assert html =~ ~s(data-home-coach-suggestion)

    {workout_index, _} = :binary.match(html, ~s(id="home-workout-card"))
    {coach_index, _} = :binary.match(html, ~s(data-home-coach-suggestion))

    assert workout_index < coach_index
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
end
