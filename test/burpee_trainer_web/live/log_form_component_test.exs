defmodule BurpeeTrainerWeb.LogFormComponentTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainerWeb.LogFormComponent

  defmodule HostLive do
    use BurpeeTrainerWeb, :live_view

    alias BurpeeTrainer.Accounts.User
    alias BurpeeTrainer.Repo
    alias BurpeeTrainerWeb.LogFormComponent

    @impl true
    def mount(_params, %{"user_id" => user_id}, socket) do
      {:ok,
       Phoenix.Component.assign(socket, current_user: Repo.get!(User, user_id), saved?: false)}
    end

    @impl true
    def handle_info({:session_saved, _events}, socket) do
      {:noreply, Phoenix.Component.assign(socket, :saved?, true)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div id="log-form-test-host" data-saved={to_string(@saved?)}>
        <.live_component
          module={LogFormComponent}
          id="test-log"
          current_user={@current_user}
          on_save={:session_saved}
        />
      </div>
      """
    end
  end

  test "empty, malformed, and future dates render validation and persist nothing", %{conn: conn} do
    user = user_fixture()
    assert {:ok, view, _html} = live_isolated(conn, HostLive, session: %{"user_id" => user.id})

    for invalid_date <- ["", "not-a-date", Date.utc_today() |> Date.add(1) |> Date.to_iso8601()] do
      view
      |> form("#log-form-test-log",
        workout_session: %{
          "burpee_count_actual" => "41",
          "duration_sec_actual" => "7",
          "log_date" => invalid_date
        }
      )
      |> render_submit()

      assert has_element?(view, "#log-date-error[role='alert']")
      assert Workouts.list_sessions(user) == []
      assert has_element?(view, "#log-form-test-host[data-saved='false']")
    end
  end

  test "forged non-string dates render validation and persist nothing", %{conn: conn} do
    user = user_fixture()
    assert {:ok, view, _html} = live_isolated(conn, HostLive, session: %{"user_id" => user.id})

    for forged_date <- [123, %{"year" => 2025}, ["2025-02-03"], true] do
      view
      |> element("#log-form-test-log")
      |> render_submit(%{
        "workout_session" => %{
          "burpee_count_actual" => "41",
          "duration_sec_actual" => "7",
          "log_date" => forged_date
        }
      })

      assert has_element?(view, "#log-date-error[role='alert']")
      assert Workouts.list_sessions(user) == []
      assert has_element?(view, "#log-form-test-host[data-saved='false']")
    end
  end

  test "forged duration, mood, and tag values validate without mutating renderer state", %{
    conn: conn
  } do
    user = user_fixture()
    assert {:ok, view, _html} = live_isolated(conn, HostLive, session: %{"user_id" => user.id})

    for {field, forged} <- [
          {"duration_sec_actual", %{"minutes" => 7}},
          {"duration_sec_actual", ["7"]},
          {"duration_sec_actual", true},
          {"burpee_count_actual", %{"count" => 41}},
          {"burpee_count_actual", ["41"]},
          {"burpee_count_actual", true}
        ] do
      params = %{
        "burpee_count_actual" => "41",
        "duration_sec_actual" => "7",
        "log_date" => Date.to_iso8601(Date.utc_today())
      }

      view
      |> element("#log-form-test-log")
      |> render_submit(%{"workout_session" => Map.put(params, field, forged)})

      assert has_element?(view, "#log-form-test-log")
      assert Workouts.list_sessions(user) == []
    end

    mood_button = element(view, "[phx-click='set_mood'][phx-value-mood='-1']")
    tag_button = element(view, "[phx-click='toggle_tag'][phx-value-tag='tired']")

    for forged <- [123, %{"mood" => 1}, ["1"], true, "unknown"] do
      render_click(mood_button, %{"mood" => forged})
      assert has_element?(view, "#log-form-test-log")
    end

    for forged <- [123, %{"tag" => "tired"}, ["tired"], true, "unknown"] do
      render_click(tag_button, %{"tag" => forged})
      assert has_element?(view, "#log-form-test-log")
    end

    assert Workouts.list_sessions(user) == []
  end

  test "the user's valid local-today date persists a now-bounded completed_at", %{conn: conn} do
    user = user_fixture()
    assert {:ok, view, _html} = live_isolated(conn, HostLive, session: %{"user_id" => user.id})
    before_save = DateTime.utc_now(:second)

    view
    |> form("#log-form-test-log",
      workout_session: %{
        "burpee_count_actual" => "41",
        "duration_sec_actual" => "7",
        "log_date" => Date.utc_today() |> Date.to_iso8601()
      }
    )
    |> render_submit()

    after_save = DateTime.utc_now(:second)
    assert has_element?(view, "#log-form-test-host[data-saved='true']")
    assert [session] = Repo.all(Workouts.WorkoutSession)
    assert session.user_id == user.id
    assert DateTime.compare(session.completed_at, before_save) in [:eq, :gt]
    assert DateTime.compare(session.completed_at, after_save) in [:eq, :lt]
  end
end
