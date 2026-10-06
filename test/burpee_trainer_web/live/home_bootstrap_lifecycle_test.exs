defmodule BurpeeTrainerWeb.HomeBootstrapLifecycleTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Accounts, Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.DesignSession
  alias BurpeeTrainer.LayoutFixtures
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan, WorkoutSession}
  alias BurpeeTrainerWeb.HomeLive

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

    Req.default_options(
      adapter: fn request ->
        barrier = make_ref()
        send(parent, {:provider_waiting, self(), barrier, request})

        receive do
          {:respond, ^barrier, body} -> {request, %Req.Response{status: 200, body: body}}
        end
      end
    )

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://provider.test/v1/chat/completions",
      api_key: "test-secret",
      model: "test/model",
      timeout_ms: 12_345
    )

    :ok
  end

  test "idle nil-bootstrap selected submit is inert with its mounted Start token", %{conn: _conn} do
    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    socket = mounted_bootstrap_socket(user)
    assert socket.assigns.bootstrap?
    assert socket.assigns.home_selection == nil
    token = socket.assigns.start_client_session_id

    assert {:noreply, ^socket} =
             HomeLive.handle_event(
               "submit_home_action",
               %{
                 "client_session_id" => token,
                 "home_adjustment" => %{"instruction" => ""}
               },
               socket
             )

    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    refute_received {:provider_waiting, _, _, _}
  end

  test "idle nil-bootstrap selected nonblank submit is inert", %{conn: _conn} do
    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    socket = mounted_bootstrap_socket(user)
    token = socket.assigns.start_client_session_id

    assert {:noreply, ^socket} =
             HomeLive.handle_event(
               "submit_home_action",
               %{
                 "client_session_id" => token,
                 "home_adjustment" => %{"instruction" => "Make it harder"}
               },
               socket
             )

    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    refute_received {:provider_waiting, _, _, _}
  end

  test "idle nil-bootstrap selected adjustment change is inert", %{conn: _conn} do
    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    socket = mounted_bootstrap_socket(user)

    assert {:noreply, ^socket} =
             HomeLive.handle_event(
               "change_adjustment",
               %{"home_adjustment" => %{"instruction" => "Make it harder"}},
               socket
             )

    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    refute_received {:provider_waiting, _, _, _}
  end

  test "bootstrap prompt limits are local at the LiveView form boundary", %{conn: conn} do
    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")

    before = %{
      recommendations: Repo.aggregate(CoachRecommendation, :count),
      sessions: Repo.aggregate(WorkoutSession, :count),
      plans: Repo.aggregate(WorkoutPlan, :count),
      contexts: Repo.aggregate(DesignSession, :count)
    }

    for prompt <- [String.duplicate("a", 501), String.duplicate("👩‍❤️‍💋‍👨", 200)] do
      view |> form("#home-bootstrap-form", home_bootstrap: %{prompt: prompt}) |> render_submit()
      assert has_element?(view, "#home-bootstrap-error")
      refute has_element?(view, "#home-bootstrap-loading")
      _ = :sys.get_state(view.pid)
      refute_received {:provider_waiting, _, _, _}

      assert %{
               recommendations: Repo.aggregate(CoachRecommendation, :count),
               sessions: Repo.aggregate(WorkoutSession, :count),
               plans: Repo.aggregate(WorkoutPlan, :count),
               contexts: Repo.aggregate(DesignSession, :count)
             } == before
    end
  end

  test "pending bootstrap preserves empty History access and rejects duplicate requests before one successful release",
       %{conn: conn} do
    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, view, _} = live(conn, ~p"/")
    start_token = :sys.get_state(view.pid).socket.assigns.start_client_session_id

    prompt = "Build intervals"
    view |> form("#home-bootstrap-form", home_bootstrap: %{prompt: prompt}) |> render_submit()
    assert_receive {:provider_waiting, worker, barrier, request}
    assert %Req.Request{} = request
    pending = bootstrap_socket(view)

    assert %{bootstrap?: true, busy?: true, bootstrap_id: pending_id, bootstrap_prompt: ^prompt} =
             pending.assigns

    assert pending.assigns.bootstrap_form.params["prompt"] == prompt
    assert pending.assigns.start_client_session_id == start_token
    assert Repo.aggregate(from(plan in WorkoutPlan, where: plan.user_id == ^user.id), :count) == 0

    assert %DesignSession{source_plan_id: nil, workspace_key: workspace_key} =
             Repo.one!(from(context in DesignSession, where: context.user_id == ^user.id))

    assert String.starts_with?(workspace_key, "home-bootstrap:")
    assert has_element?(view, "#home-bootstrap-loading")
    assert has_element?(view, "#home-workout-area[aria-busy='true']")
    refute has_element?(view, "#home-bootstrap-form")
    assert Repo.aggregate(CoachRecommendation, :count) == 0

    assert has_element?(view, "#home-history-toggle")
    view |> element("#home-history-toggle") |> render_click()
    assert has_element?(view, "#home-history-empty")
    refute has_element?(view, "#home-history-weekly")
    view |> element("#home-history-close") |> render_click()
    assert_patch(view, "/")
    still_pending = bootstrap_socket(view)
    assert still_pending.assigns.bootstrap_id == pending_id
    assert still_pending.assigns.bootstrap_prompt == prompt
    assert still_pending.assigns.bootstrap_form.params["prompt"] == prompt
    assert still_pending.assigns.start_client_session_id == start_token

    render_submit(view, "submit_bootstrap", %{"home_bootstrap" => %{"prompt" => "Second request"}})

    render_submit(view, "submit_home_action", %{
      "client_session_id" => start_token,
      "home_adjustment" => %{"instruction" => ""}
    })

    render_click(view, "select_alternative", %{"kind" => "plan", "id" => "1"})
    assert has_element?(view, "#home-bootstrap-loading")
    refute has_element?(view, "#home-bootstrap-error")
    _ = :sys.get_state(view.pid)
    refute_received {:provider_waiting, _, _, _}
    assert Repo.aggregate(CoachRecommendation, :count) == 0
    assert Repo.aggregate(WorkoutSession, :count) == 0

    send(worker, {:respond, barrier, provider_body(extracted_request())})
    render_async(view)
    assert has_element?(view, "#home-request-confirmation")
    refute has_element?(view, "#home-summary")
    assert Repo.aggregate(CoachRecommendation, :count) == 0

    view |> element("#home-request-confirm") |> render_click()
    assert_receive {:provider_waiting, planner, planning_barrier, _planning_request}
    render_click(view, "confirm_workout_request", %{})
    _ = :sys.get_state(view.pid)
    refute_received {:provider_waiting, _, _, _}
    send(planner, {:respond, planning_barrier, provider_body(layout("Bootstrap intervals"))})
    render_async(view)

    refute has_element?(view, "#home-history")
    assert has_element?(view, "#home-history-toggle")
    assert has_element?(view, "#home-summary")
    assert has_element?(view, "#home-action[aria-label='Start workout'] .hero-play")
    assert has_element?(view, "#home-expansion[data-open='true']")
    refute has_element?(view, "#home-bootstrap-loading")
    assert Repo.aggregate(CoachRecommendation, :count) == 1
    refute client_session_id(view) == start_token

    assert %CoachRecommendation{home_workout_plan_id: selected_plan_id} =
             Repo.one!(
               from(recommendation in CoachRecommendation,
                 where: recommendation.user_id == ^user.id
               )
             )

    assert %WorkoutPlan{id: ^selected_plan_id, user_id: user_id, state: :draft, origin: :user} =
             Repo.get!(WorkoutPlan, selected_plan_id)

    assert user_id == user.id
    assert Workouts.current_started_session(Scope.for_user(user)) == nil
    first_token = client_session_id(view)

    {:ok, reloaded, _} = live(conn, ~p"/")
    assert has_element?(reloaded, "#home-summary", "Bootstrap intervals")
    assert has_element?(reloaded, "#home-action[aria-label='Start workout'] .hero-play")
    refute client_session_id(reloaded) == first_token
  end

  test "provider failure restores exact prompt and explicit retry is the only further request", %{
    conn: conn
  } do
    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    prompt = "  A careful\nfirst workout  "

    view |> form("#home-bootstrap-form", home_bootstrap: %{prompt: prompt}) |> render_submit()
    assert_receive {:provider_waiting, worker, barrier, request}
    assert %Req.Request{} = request
    failed_pending = bootstrap_socket(view)
    assert failed_pending.assigns.bootstrap_prompt == prompt
    assert failed_pending.assigns.bootstrap_form.params["prompt"] == prompt

    assert %DesignSession{id: context_id, source_plan_id: nil, workspace_key: workspace_key} =
             Repo.one!(from(context in DesignSession, where: context.user_id == ^user.id))

    assert String.starts_with?(workspace_key, "home-bootstrap:")

    send(
      worker,
      {:respond, barrier,
       Jason.encode!(%{"choices" => [%{"message" => %{"content" => "not-json"}}]})}
    )

    render_async(view)

    assert has_element?(view, "#home-bootstrap-form")
    assert has_element?(view, "#home-bootstrap-error")
    assert input_value(view, "#home-bootstrap-prompt") == prompt
    restored = bootstrap_socket(view)
    assert restored.assigns.bootstrap_prompt == prompt
    assert restored.assigns.bootstrap_form.params["prompt"] == prompt
    _ = :sys.get_state(view.pid)
    refute_received {:provider_waiting, _, _, _}
    assert Repo.aggregate(CoachRecommendation, :count) == 0

    view |> form("#home-bootstrap-form", home_bootstrap: %{prompt: prompt}) |> render_submit()
    assert_receive {:provider_waiting, retry_worker, retry_barrier, retry_request}
    assert %Req.Request{} = retry_request

    assert %DesignSession{id: ^context_id, source_plan_id: nil} =
             Repo.one!(from(context in DesignSession, where: context.user_id == ^user.id))

    send(retry_worker, {:respond, retry_barrier, provider_body(extracted_request())})
    render_async(view)
    assert has_element?(view, "#home-request-confirmation")
    refute has_element?(view, "#home-summary")

    view |> element("#home-request-confirm") |> render_click()
    assert_receive {:provider_waiting, planner, planning_barrier, _planning_request}
    send(planner, {:respond, planning_barrier, provider_body(layout("Retried bootstrap"))})
    render_async(view)

    assert has_element?(view, "#home-summary")
    assert has_element?(view, "#home-action[aria-label='Start workout'] .hero-play")
    assert Repo.aggregate(CoachRecommendation, :count) == 1

    render_submit(view, "submit_home_action", %{
      "client_session_id" => client_session_id(view),
      "home_adjustment" => %{"instruction" => "Make it gentler"}
    })

    assert_receive {:provider_waiting, update_worker, update_barrier, _update_request}

    send(update_worker, {:respond, update_barrier, provider_body(extracted_request())})
    render_async(view)
    assert has_element?(view, "#home-request-confirmation")

    view |> element("#home-request-confirm") |> render_click()
    assert_receive {:provider_waiting, updater, updater_barrier, _update_plan_request}
    render_click(view, "confirm_workout_request", %{})
    _ = :sys.get_state(view.pid)
    refute_received {:provider_waiting, _, _, _}
    send(updater, {:respond, updater_barrier, provider_body(layout("Refined bootstrap"))})
    render_async(view)
    assert has_element?(view, "#home-summary")
    assert has_element?(view, "#home-action[aria-label='Start workout'] .hero-play")

    render_submit(view, "submit_home_action", %{
      "client_session_id" => client_session_id(view),
      "home_adjustment" => %{"instruction" => ""}
    })

    assert %{state: :started} = Workouts.current_started_session(Scope.for_user(user))
  end

  test "bootstrap built-in selection enters the selected workspace without a provider request", %{
    conn: conn
  } do
    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")

    plan =
      Repo.one!(
        from(plan in WorkoutPlan,
          where: is_nil(plan.user_id) and plan.origin == :built_in and plan.state == :published,
          limit: 1
        )
      )

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    view |> element("#home-alternative-plan-#{plan.id}-select") |> render_click()

    assert has_element?(view, "#home-summary", plan.name)
    assert has_element?(view, "#home-action[aria-label='Start workout'] .hero-play")
    refute has_element?(view, "#home-bootstrap-form")
    refute has_element?(view, "#home-bootstrap")
    first_token = client_session_id(view)

    assert %CoachRecommendation{home_workout_plan_id: selected_plan_id} =
             Repo.one!(
               from(recommendation in CoachRecommendation,
                 where: recommendation.user_id == ^user.id
               )
             )

    assert selected_plan_id == plan.id
    {:ok, reloaded, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    assert has_element?(reloaded, "#home-summary", plan.name)
    assert has_element?(reloaded, "#home-action[aria-label='Start workout'] .hero-play")
    refute client_session_id(reloaded) == first_token

    render_submit(reloaded, "submit_home_action", %{
      "client_session_id" => client_session_id(reloaded),
      "home_adjustment" => %{"instruction" => ""}
    })

    assert %{plan_id: plan_id, state: :started} =
             Workouts.current_started_session(Scope.for_user(user))

    assert plan_id == plan.id
    _ = :sys.get_state(view.pid)
    refute_received {:provider_waiting, _, _, _}
  end

  test "nil bootstrap video alternative is reachable and selectable without a provider request",
       %{conn: conn} do
    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    video = video_fixture(%{burpee_count: 60})
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")

    assert has_element?(view, "#home-bootstrap-alternatives")
    view |> element("#home-tab-videos") |> render_click()
    assert has_element?(view, "#home-tab-videos[aria-selected='true']")
    _ = :sys.get_state(view.pid)
    refute_received {:provider_waiting, _, _, _}
    view |> element("#home-alternative-video-#{video.id}-select") |> render_click()
    assert %{workout_video_id: video_id} = Workouts.current_started_session(Scope.for_user(user))
    assert video_id == video.id
    refute_received {:provider_waiting, _, _, _}
  end

  defp mounted_bootstrap_socket(user) do
    socket = %Phoenix.LiveView.Socket{
      endpoint: BurpeeTrainerWeb.Endpoint,
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{
        __changed__: %{},
        current_scope: BurpeeTrainer.Accounts.Scope.for_user(user),
        current_level: :level_1a,
        flash: %{},
        home_now: fn -> DateTime.utc_now(:second) end
      }
    }

    {:ok, socket} = HomeLive.mount(%{}, %{}, socket)
    socket
  end

  defp bootstrap_socket(view), do: :sys.get_state(view.pid).socket

  defp client_session_id(view) do
    [id] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-action")
      |> LazyHTML.attribute("phx-value-client_session_id")

    id
  end

  defp input_value(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
  end

  defp provider_body(workout_definition) do
    Jason.encode!(%{
      "choices" => [%{"message" => %{"content" => Jason.encode!(workout_definition)}}]
    })
  end

  defp extracted_request do
    %{
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "even",
      "recovery" => "optional",
      "timed_rests" => [],
      "requested_pace_sec" => nil
    }
  end

  defp layout(name), do: LayoutFixtures.layout([[{10, 12.0, 12.0}]], name)
end
