defmodule BurpeeTrainerWeb.HomeLiveStateTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  import Ecto.Query
  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}
  alias BurpeeTrainerWeb.HomeLive

  @now ~U[2026-09-09 12:00:00Z]

  test "start renders exactly the real Start control", %{conn: conn} do
    user = user_fixture()
    plan_fixture(user)
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")

    assert has_element?(
             view,
             "#home-page[data-home-state=start] #home-action[data-primary-action=start]"
           )

    assert_primary(render(view), "start", "start", "home-action")
  end

  test "resume wins over completion and renders only Resume" do
    user = user_fixture()
    plan = plan_fixture(user)
    {:ok, started} = Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())
    complete(user, @now, 4800)
    socket = mount_home(user)
    assert_primary(render_home(socket), "resume", "resume", "resume-recommended-workout")
    assert socket.assigns.started_session.id == started.id
    assert Repo.reload!(started) == started
  end

  test "first workout renders exactly the existing prompt's primary submit" do
    socket = mount_home(user_fixture())

    assert_primary(
      render_home(socket),
      "first_workout",
      "describe_first",
      "home-bootstrap-submit"
    )

    assert socket.assigns.bootstrap?
  end

  test "choose is reachable through legitimate missing fallback and opens chooser" do
    user = user_fixture()
    complete(user, DateTime.add(@now, -90 * 86400), 1200)

    Repo.update_all(from(p in WorkoutPlan, where: is_nil(p.user_id) and p.origin == :built_in),
      set: [state: :archived, archived_at: @now]
    )

    socket = mount_home(user)
    assert_primary(render_home(socket), "choose", "choose", "home-title-action")
    assert socket.assigns.home_selection == nil
  end

  test "done today renders exactly the existing History Insights link" do
    user = user_fixture()
    complete(user, @now, 1200)
    socket = mount_home(user)
    assert_primary(render_home(socket), "done_today", "insights", "home-history-toggle")
  end

  test "week complete renders exactly the existing History Insights link" do
    user = user_fixture()
    complete(user, DateTime.add(@now, -86400), 4800)
    socket = mount_home(user)
    assert_primary(render_home(socket), "week_complete", "insights", "home-history-toggle")
  end

  test "invalid timezone renders the real error and no fabricated state or primary" do
    user = %{user_fixture() | timezone: "Invalid/Zone"}
    socket = mount_home(user)
    html = render_home(socket) |> LazyHTML.from_fragment()
    assert LazyHTML.query(html, "#home-unavailable") |> Enum.count() == 1
    assert LazyHTML.query(html, "[data-primary-action]") |> Enum.empty?()
    refute Map.has_key?(socket.assigns, :home_facts) and socket.assigns.home_facts != nil
    assert socket.assigns.home_state == nil
  end

  defp assert_primary(html, state, action, id) do
    html = LazyHTML.from_fragment(html)
    assert LazyHTML.query(html, "#home-page[data-home-state=#{state}]") |> Enum.count() == 1
    assert LazyHTML.query(html, "[data-primary-action]") |> Enum.count() == 1
    assert LazyHTML.query(html, "##{id}[data-primary-action=#{action}]") |> Enum.count() == 1
  end

  defp mount_home(user) do
    socket = %Phoenix.LiveView.Socket{
      endpoint: BurpeeTrainerWeb.Endpoint,
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{
        __changed__: %{},
        current_scope: Scope.for_user(user),
        current_level: :level_1a,
        flash: %{},
        home_now: fn -> @now end
      }
    }

    {:ok, socket} = HomeLive.mount(%{}, %{}, socket)
    socket
  end

  defp render_home(socket), do: render_component(&HomeLive.render/1, socket.assigns)

  defp complete(user, at, seconds) do
    Repo.insert!(%WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      display_name_snapshot: "Saved",
      workout_type_snapshot: :six_count,
      burpee_type: :six_count,
      burpee_count_actual: 20,
      duration_sec_actual: seconds,
      completed_at: at,
      capture_mode: :logged
    })
  end
end
