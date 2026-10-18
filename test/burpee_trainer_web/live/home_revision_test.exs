defmodule BurpeeTrainerWeb.HomeRevisionTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Repo, ReqStub, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.LayoutFixtures
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan, WorkoutSession}

  setup do
    parent = self()
    previous_req = Req.default_options()
    previous_provider = Application.get_env(:burpee_trainer, :llm_provider)

    on_exit(fn ->
      Req.default_options(previous_req)

      if previous_provider == nil,
        do: Application.delete_env(:burpee_trainer, :llm_provider),
        else: Application.put_env(:burpee_trainer, :llm_provider, previous_provider)
    end)

    ReqStub.default(fn request ->
      send(parent, {:provider_waiting, self()})

      receive do
        {:respond, body} -> {request, %Req.Response{status: 200, body: body}}
      end
    end)

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://provider.test/v1",
      api_key: "test",
      model: "test"
    )

    :ok
  end

  test "only loading remains, overlap is ignored, failure restores exact source", %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    seed_past_history(user)
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()

    render_click(view, "toggle_filters", %{})

    for level <- BurpeeTrainer.Levels.all_levels() do
      selector = "#home-level-#{level}[aria-pressed='false']"

      if has_element?(view, selector),
        do: view |> element(selector) |> render_click(%{"value" => ""})
    end

    assert has_element?(view, "#home-alternatives")

    [token] =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-action")
      |> LazyHTML.attribute("phx-value-client_session_id")

    render_click(view, "submit_home_action", %{
      "client_session_id" => token,
      "home_adjustment" => %{"instruction" => "Less rest"}
    })

    assert_receive {:provider_waiting, worker}
    plans_before_history = Repo.all(WorkoutPlan)
    recommendation_before_history = Repo.get!(CoachRecommendation, shown.recommendation_id)
    view |> element("#home-history-toggle") |> render_click()
    assert has_element?(view, "#home-history")
    view |> element("#home-history-period-all") |> render_click()
    view |> element("#home-history-close") |> render_click()
    assert_patch(view, "/")
    assert has_element?(view, "#home-update-loading")
    view |> element("#home-history-toggle") |> render_click()

    render_click(view, "select_alternative", %{"kind" => "plan", "id" => to_string(shown.plan.id)})

    render_click(view, "submit_home_action", %{
      "client_session_id" => token,
      "home_adjustment" => %{"instruction" => "Another request"}
    })

    _ = :sys.get_state(view.pid)
    refute_received {:provider_waiting, _}
    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    assert Repo.all(WorkoutPlan) == plans_before_history
    assert Repo.reload!(recommendation_before_history) == recommendation_before_history
    refute has_element?(view, "#home-update-loading, #home-workout-area")
    assert :sys.get_state(view.pid).socket.assigns.busy?
    assert has_element?(view, "#home-history-heading")

    for selector <- ["#home-summary", "#home-inspection", "#home-adjustment-form", "#home-action"] do
      refute has_element?(view, selector)
    end

    render_click(view, "submit_home_action", %{
      "client_session_id" => token,
      "home_adjustment" => %{"instruction" => ""}
    })

    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    _ = :sys.get_state(view.pid)
    refute_received {:provider_waiting, _}

    send(
      worker,
      {:respond, Jason.encode!(%{"choices" => [%{"message" => %{"content" => "not-json"}}]})}
    )

    render_async(view)
    assert has_element?(view, "#home-history")
    assert has_element?(view, "#home-history-period-all[aria-pressed=true]")
    view |> element("#home-history-close") |> render_click()
    assert_patch(view, "/")
    assert has_element?(view, "#home-summary")
    assert has_element?(view, "#home-workout-area[aria-busy='false']")
    assert has_element?(view, "#home-alternatives")
    assert :sys.get_state(view.pid).socket.assigns.instruction == "Less rest"
    assert has_element?(view, "#home-action[aria-label='Start workout'] .hero-play-solid")
    assert has_element?(view, "#home-adjustment-error")
    {:ok, after_failure} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    assert after_failure.plan.content_hash == shown.plan.content_hash
    assert after_failure.home_revision == shown.home_revision
    assert Repo.all(WorkoutPlan) == plans_before_history
    assert Repo.reload!(recommendation_before_history) == recommendation_before_history

    render_click(view, "submit_home_action", %{
      "client_session_id" => token,
      "home_adjustment" => %{"instruction" => "Rename this workout"}
    })

    assert_receive {:provider_waiting, retry_worker}
    view |> element("#home-history-toggle") |> render_click()
    assert has_element?(view, "#home-history")
    layout = layout_from_definition(shown.plan.definition_json, "Revised in Home")

    extracted = %{
      "burpee_type" => Atom.to_string(shown.plan.burpee_type),
      "target_reps" => shown.plan.target_reps,
      "target_duration_sec" => shown.plan.target_duration_sec,
      "pacing_style" => shown.plan.definition_json["pacing_style"],
      "recovery" => "optional",
      "timed_rests" => [],
      "requested_pace_sec" => nil
    }

    send(
      retry_worker,
      {:respond,
       Jason.encode!(%{"choices" => [%{"message" => %{"content" => Jason.encode!(extracted)}}]})}
    )

    render_async(view)
    assert has_element?(view, "#home-history")
    refute has_element?(view, "#home-request-confirmation")
    assert :sys.get_state(view.pid).socket.assigns.pending_request
    view |> element("#home-history-close") |> render_click()
    assert_patch(view, "/")
    assert has_element?(view, "#home-request-confirmation")
    view |> element("#home-request-confirm") |> render_click()
    assert_receive {:provider_waiting, planner}
    view |> element("#home-history-toggle") |> render_click()
    assert_patch(view, "/progress")

    send(
      planner,
      {:respond,
       Jason.encode!(%{"choices" => [%{"message" => %{"content" => Jason.encode!(layout)}}]})}
    )

    render_async(view)
    assert has_element?(view, "#home-history")
    assert has_element?(view, "#home-history-period-all[aria-pressed=true]")
    view |> element("#home-history-close") |> render_click()
    assert_patch(view, "/")
    assert has_element?(view, "#home-summary", "Revised in Home")
    assert has_element?(view, "#home-action[aria-label='Start workout'] .hero-play-solid")
    assert has_element?(view, "#home-expansion[data-open='true']")
    {:ok, revised} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    assert revised.home_revision == shown.home_revision + 1
    assert revised.plan.state == :draft
    assert revised.plan.user_id == user.id
    refute revised.plan.id == shown.plan.id
    assert {:ok, verified} = Workouts.verify_home_selection(Scope.for_user(user), revised)
    assert verified.id == revised.plan.id
    for plan <- plans_before_history, do: assert(Repo.reload!(plan) == plan)
    assert Repo.aggregate(WorkoutPlan, :count) == length(plans_before_history) + 1
    assert Repo.aggregate(WorkoutSession, :count) == 1

    [new_token] =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-action")
      |> LazyHTML.attribute("phx-value-client_session_id")

    refute token == new_token
    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    refute_received {:provider_waiting, _}
  end

  test "stale slot while provider waits rejects a valid response without an orphan draft or Start",
       %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    seed_past_history(user)
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()
    plans_before = Repo.all(WorkoutPlan)

    [token] =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-action")
      |> LazyHTML.attribute("phx-value-client_session_id")

    render_click(view, "submit_home_action", %{
      "client_session_id" => token,
      "home_adjustment" => %{"instruction" => "Rename this workout"}
    })

    assert_receive {:provider_waiting, worker}
    view |> element("#home-history-toggle") |> render_click()
    view |> element("#home-history-period-all") |> render_click()

    stale =
      Repo.get!(CoachRecommendation, shown.recommendation_id)
      |> Ecto.Changeset.change(slot_key: "obsolete-slot")
      |> Repo.update!()

    extracted = %{
      "burpee_type" => Atom.to_string(shown.plan.burpee_type),
      "target_reps" => shown.plan.target_reps,
      "target_duration_sec" => shown.plan.target_duration_sec,
      "pacing_style" => shown.plan.definition_json["pacing_style"],
      "recovery" => "optional",
      "timed_rests" => [],
      "requested_pace_sec" => nil
    }

    send(
      worker,
      {:respond,
       Jason.encode!(%{"choices" => [%{"message" => %{"content" => Jason.encode!(extracted)}}]})}
    )

    render_async(view)

    assert has_element?(view, "#home-history")
    assert has_element?(view, "#home-history-period-all[aria-pressed=true]")
    view |> element("#home-history-close") |> render_click()
    assert_patch(view, "/")
    assert has_element?(view, "#home-summary", shown.plan.name)
    assert :sys.get_state(view.pid).socket.assigns.instruction == "Rename this workout"
    assert has_element?(view, "#home-action[aria-label='Start workout'] .hero-play-solid")
    assert has_element?(view, "#home-adjustment-error")
    assert Repo.all(WorkoutPlan) == plans_before
    assert Repo.reload!(stale) == stale
    assert Repo.reload!(shown.plan) == shown.plan
    assert Workouts.current_started_session(Scope.for_user(user)) == nil

    render_click(view, "submit_home_action", %{
      "client_session_id" => token,
      "home_adjustment" => %{"instruction" => ""}
    })

    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    assert Repo.aggregate(WorkoutSession, :count) == 1
    assert Repo.all(WorkoutPlan) == plans_before
    refute_received {:provider_waiting, _}
  end

  defp layout_from_definition(definition, name) do
    sets =
      for %{"kind" => "work"} = event <- definition["events"] do
        {event["reps"], event["sec_per_rep"], event["sec_per_burpee"]}
      end

    LayoutFixtures.layout([sets], name)
  end

  defp seed_past_history(user) do
    Repo.insert!(%WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      capture_mode: :logged,
      burpee_type: :six_count,
      completed_at: DateTime.add(DateTime.utc_now(:second), -90 * 86400),
      burpee_count_actual: 10,
      duration_sec_actual: 1200
    })
  end
end
