defmodule BurpeeTrainerWeb.WorkspaceReentryTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Notebook
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    %{conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "plan rows replay after History and Coach without resetting filters or working forms", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user, %{target_reps: 10})
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()
    view |> element("#home-new-workout") |> render_click()
    view |> form("#home-new-form", home_workout: %{note: "20 sets of 6"}) |> render_change()
    render_click(view, "filter", %{"kind" => "type", "filter" => "navy_seal"})
    render_click(view, "open_chooser")
    assert has_element?(view, "#home-alternative-plan-#{plan.id}-select")
    before = workspace(view)
    rows = Repo.all(WorkoutPlan)
    sessions = Workouts.list_sessions(Scope.for_user(user))

    for via <- [:history, :coach] do
      roundtrip(view, via)
      assert has_element?(view, "#home-alternative-plan-#{plan.id}-select")
      assert workspace(view) == before
      assert :sys.get_state(view.pid).socket.assigns.workout_form[:note].value == "20 sets of 6"
      assert has_element?(view, "#home-expansion[data-open=true]")
      assert Repo.all(WorkoutPlan) == rows
      assert Workouts.list_sessions(Scope.for_user(user)) == sessions
      assert Notebook.get(Scope.for_user(user)).body == ""
    end

    view |> element("#home-alternative-plan-#{plan.id}-select") |> render_click()
    assert :sys.get_state(view.pid).socket.assigns.home_selection.plan.id == plan.id
    # New still holds the screen, and its working form survives the choice.
    assert has_element?(view, "#home-new-form")
    refute has_element?(view, "#home-title-action")
  end

  test "the real Switch control reopens plan choices without needing a tab or filter refresh", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user_fixture(), %{target_reps: 10})
    owned = plan_fixture(user, %{target_reps: 10})
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()
    view |> element("#home-title-action") |> render_click()
    assert has_element?(view, "#home-alternative-plan-#{owned.id}-select")
    refute has_element?(view, "#home-alternative-plan-#{plan.id}-select")
    roundtrip(view, :history)
    assert has_element?(view, "#home-alternative-plan-#{owned.id}-select")
    view |> element("#home-chooser-close") |> render_click()
    view |> element("#home-title-action") |> render_click()
    view |> element("#home-alternative-plan-#{owned.id}-select") |> render_click()
    assert :sys.get_state(view.pid).socket.assigns.home_selection.plan.id == owned.id
    assert Repo.reload!(plan) == plan
  end

  test "video rows replay and remain startable after both workspace routes", %{
    conn: conn,
    user: user
  } do
    plan_fixture(user)
    video = video_fixture(%{burpee_count: 10, duration_sec: 120})
    {:ok, view, _} = live(conn, ~p"/")
    render_click(view, "tab", %{"tab" => "videos"})
    render_click(view, "open_chooser")
    assert has_element?(view, "#home-alternative-video-#{video.id}-select")
    before = workspace(view)

    for via <- [:history, :coach] do
      roundtrip(view, via)
      assert has_element?(view, "#home-alternative-video-#{video.id}-select")
      assert workspace(view) == before
      assert Workouts.current_started_session(Scope.for_user(user)) == nil
    end

    view |> element("#home-alternative-video-#{video.id}-select") |> render_click()
    started = Workouts.current_started_session(Scope.for_user(user))
    assert started.workout_video_id == video.id
    assert_redirect(view, ~p"/videos/#{video.id}/session/#{started.id}")
  end

  test "deleting today's completion restores an existing user's immediately startable fallback",
       %{conn: conn, user: user} do
    plan_fixture(user)
    saved = complete(user)
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#home-done-today")
    assert :sys.get_state(view.pid).socket.assigns.home_selection == nil
    delete_completion(view, saved)
    close_history(view)
    refute has_element?(view, "#retry-recommendation-button")
    selected = :sys.get_state(view.pid).socket.assigns.home_selection
    assert selected.plan.id
    assert {:ok, _} = Workouts.verify_home_selection(Scope.for_user(user), selected)
    assert has_element?(view, "#home-action[aria-label='Start workout']:not([disabled])")
    view |> element("#home-action") |> render_click()
    started = Workouts.current_started_session(Scope.for_user(user))
    assert started.plan_id == selected.plan.id
    assert_redirect(view, ~p"/session/#{started.id}")
  end

  test "deleting the only completion restores the first-use starter", %{
    conn: conn,
    user: user
  } do
    saved = complete(user)
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#home-done-today")
    delete_completion(view, saved)
    close_history(view)
    refute has_element?(view, "#retry-recommendation-button")
    assert has_element?(view, "#home-action[aria-label='Start workout']:not([disabled])")
    assert :sys.get_state(view.pid).socket.assigns.home_selection.plan.name == "Starter Six-Count"
    assert Workouts.list_sessions(Scope.for_user(user)) == []
  end

  test "successful deletion never resets a mounted working selection or new-workout draft", %{
    conn: conn,
    user: user
  } do
    plan_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()
    view |> element("#home-new-workout") |> render_click()
    view |> form("#home-new-form", home_workout: %{note: "20 sets of 6"}) |> render_change()
    before = workspace(view)
    plans = Repo.all(WorkoutPlan)
    saved = complete(user)
    delete_completion(view, saved)
    close_history(view)
    assert workspace(view) == before
    assert has_element?(view, "#home-new-form")
    assert :sys.get_state(view.pid).socket.assigns.workout_form[:note].value == "20 sets of 6"
    assert Repo.all(WorkoutPlan) == plans
    assert Workouts.current_started_session(Scope.for_user(user)) == nil
  end

  test "delete and reentry preserve a real in-flight authoring identity and Start token", %{
    conn: conn,
    user: user
  } do
    parent = self()
    previous_req = Req.default_options()
    previous_provider = Application.get_env(:burpee_trainer, :llm_provider)

    on_exit(fn ->
      Req.default_options(previous_req)

      if previous_provider,
        do: Application.put_env(:burpee_trainer, :llm_provider, previous_provider),
        else: Application.delete_env(:burpee_trainer, :llm_provider)
    end)

    Req.default_options(
      adapter: fn request ->
        send(parent, {:provider_waiting, self()})

        receive do
          :release ->
            {request,
             %Req.Response{
               status: 200,
               body: Jason.encode!(%{"choices" => [%{"message" => %{"content" => "not-json"}}]})
             }}
        end
      end
    )

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://provider.test/v1",
      api_key: "test",
      model: "test"
    )

    plan_fixture(user)
    {:ok, view, _} = live(conn, ~p"/")
    token = :sys.get_state(view.pid).socket.assigns.start_client_session_id

    render_click(view, "submit_home_action", %{
      "client_session_id" => token,
      "home_adjustment" => %{"instruction" => "Less rest"}
    })

    assert_receive {:provider_waiting, worker}
    before = workspace(view)
    assert before.busy?
    assert before.update_id
    saved = complete(user)
    delete_completion(view, saved)
    close_history(view)
    assert workspace(view) == before
    assert has_element?(view, "#home-workout-area[aria-busy=true]")
    assert Repo.reload!(before.home_selection.plan) == before.home_selection.plan
    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    refute_received {:provider_waiting, _}
    send(worker, :release)
    render_async(view)
    assert :sys.get_state(view.pid).socket.assigns.instruction == "Less rest"
    assert :sys.get_state(view.pid).socket.assigns.home_selection == before.home_selection
    assert :sys.get_state(view.pid).socket.assigns.start_client_session_id == token
    assert has_element?(view, "#home-action[aria-label='Start workout']:not([disabled])")
  end

  defp workspace(view) do
    :sys.get_state(view.pid).socket.assigns
    |> Map.take([
      :home_selection,
      :filters,
      :filters_open?,
      :active_tab,
      :expanded?,
      :chooser_open?,
      :start_client_session_id,
      :instruction,
      :authoring_stage,
      :workout_parameters,
      :pending_request,
      :busy?,
      :update_id,
      :creation_key
    ])
  end

  defp roundtrip(view, via) do
    pid = view.pid
    view |> element("#home-history-toggle") |> render_click()
    assert_patch(view, "/progress")

    if via == :coach do
      # An old Coach link lands on Home.
      render_patch(view, ~p"/coach")
      assert_patch(view, "/")
    else
      close_history(view)
    end

    assert view.pid == pid
  end

  defp close_history(view) do
    view |> element("#home-history-close") |> render_click()
    assert_patch(view, "/")
  end

  defp delete_completion(view, saved) do
    pid = view.pid
    view |> element("#home-history-toggle") |> render_click()
    assert_patch(view, "/progress")
    view |> element("#home-history-inspect-#{saved.id}") |> render_click()
    # The first tap on the trash arms it; the second deletes.
    view |> element("#home-history-delete-#{saved.id}") |> render_click()
    view |> element("#home-history-delete-#{saved.id}") |> render_click()
    assert Repo.get(WorkoutSession, saved.id) == nil
    assert view.pid == pid
  end

  defp complete(user) do
    Repo.insert!(%WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      display_name_snapshot: "Saved",
      workout_type_snapshot: :six_count,
      burpee_type: :six_count,
      burpee_count_actual: 20,
      duration_sec_actual: 1200,
      completed_at: DateTime.utc_now(:second),
      capture_mode: :logged
    })
  end
end
