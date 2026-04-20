defmodule BurpeeTrainerWeb.LogLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "renders the form", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/log")
    assert html =~ "Log session"
    assert html =~ "Burpees done"
  end

  test "saves a session with a custom date", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, ~p"/log")

    params = %{
      "burpee_type" => "navy_seal",
      "burpee_count_actual" => "42",
      "duration_min" => "5",
      "date" => "2026-01-15",
      "note_post" => "tough"
    }

    view
    |> form("#log-form", workout_session: params)
    |> render_submit()
    |> follow_redirect(conn, ~p"/history")

    assert [session] = Workouts.list_sessions(user)
    assert session.burpee_type == :navy_seal
    assert session.burpee_count_actual == 42
    assert session.duration_sec_actual == 300
    assert session.plan_id == nil
    assert session.inserted_at |> DateTime.to_date() == ~D[2026-01-15]
  end

  test "validation errors re-render", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/log")

    html =
      view
      |> form("#log-form",
        workout_session: %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => "",
          "duration_min" => ""
        }
      )
      |> render_submit()

    assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
  end
end
