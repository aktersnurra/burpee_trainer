defmodule BurpeeTrainerWeb.OverviewBootstrapTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Coach, Repo, Workouts}
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan, WorkoutSession}
  alias BurpeeTrainerWeb.OverviewLive

  setup do
    previous_req = Req.default_options()
    parent = self()
    Req.default_options(adapter: fn _request -> send(parent, :unexpected_provider) end)
    on_exit(fn -> Req.default_options(previous_req) end)
    :ok
  end

  test "fresh Home renders the bootstrap prompt without a fallback pointer", %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#home-bootstrap-form")
    assert has_element?(view, "#home-bootstrap-prompt[name='home_bootstrap[prompt]']")
    assert has_element?(view, "#home-bootstrap-form label[for='home-bootstrap-prompt']")
    assert has_element?(view, "#home-bootstrap-submit")
    assert has_element?(view, "#home-bootstrap-alternatives")
    refute has_element?(view, "#home-summary")
    assert Repo.aggregate(CoachRecommendation, :count) == 0
  end

  test "blank bootstrap submission stays local and alternatives need no provider", %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    previous = Req.default_options()
    parent = self()

    Req.default_options(adapter: fn _ -> send(parent, :unexpected_provider) end)
    on_exit(fn -> Req.default_options(previous) end)

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    view |> form("#home-bootstrap-form", home_bootstrap: %{prompt: "   "}) |> render_submit()
    assert has_element?(view, "#home-bootstrap-error")
    view |> element("#home-tab-videos") |> render_click()
    assert has_element?(view, "#home-tab-videos[aria-selected=true]")
    assert Workouts.current_started_session(user) == nil
    refute_received :unexpected_provider
  end

  test "obsolete bootstrap completion leaves a newer pending request and token exactly intact", %{
    conn: _conn
  } do
    {_user, _now, _slot, old_id, _req, socket, _selected, _alternative} =
      committed_pending_bootstrap()

    newer_id = make_ref()
    newer_token = Ecto.UUID.generate()

    newer_socket =
      Phoenix.Component.assign(socket,
        bootstrap_id: newer_id,
        bootstrap_prompt: "Newer request",
        bootstrap_form:
          Phoenix.Component.to_form(%{"prompt" => "Newer request"}, as: :home_bootstrap),
        start_client_session_id: newer_token,
        history_open?: true,
        busy?: true
      )

    assert {:noreply, ^newer_socket} =
             OverviewLive.handle_async(
               {:home_bootstrap, old_id},
               {:ok, {:error, :obsolete}},
               newer_socket
             )

    assert newer_socket.assigns.bootstrap_id == newer_id
    assert newer_socket.assigns.start_client_session_id == newer_token
    assert newer_socket.assigns.bootstrap_form.params["prompt"] == "Newer request"
  end

  test "duplicate matching bootstrap completion preserves selected identity and Start token", %{
    conn: _conn
  } do
    {_user, _now, _slot, id, _req, socket, selected, _alternative} = committed_pending_bootstrap()

    assert {:noreply, completed} =
             OverviewLive.handle_async({:home_bootstrap, id}, {:ok, {:ok, selected}}, socket)

    selected_id = completed.assigns.home_selection.recommendation_id
    token = completed.assigns.start_client_session_id
    html = rendered(completed)

    assert {:noreply, ^completed} =
             OverviewLive.handle_async({:home_bootstrap, id}, {:ok, {:ok, selected}}, completed)

    assert completed.assigns.home_selection.recommendation_id == selected_id
    assert completed.assigns.start_client_session_id == token
    assert selector?(html, "#home-summary")
    assert selector?(html, "#home-action")
  end

  test "bootstrap delivery rejects a replaced pointer without a stale Start", %{conn: _conn} do
    {user, _now, expected_slot, id, _req, socket, selected, alternative} =
      committed_pending_bootstrap()

    {:ok, replacement} = Workouts.ensure_home_selection(user, expected_slot)
    {:ok, _replacement} = Workouts.select_home_workout(user, replacement, alternative.id)

    assert_delivery_rejected(user, id, selected, socket, "Build intervals", false)
  end

  test "bootstrap delivery rejects a recommendation slot-date mismatch", %{conn: _conn} do
    {user, _now, expected_slot, id, _req, socket, selected, _alternative} =
      committed_pending_bootstrap()

    {1, nil} =
      Repo.update_all(
        from(r in CoachRecommendation, where: r.id == ^selected.recommendation_id),
        set: [slot_date: Date.add(expected_slot.slot_date, -1)]
      )

    assert_delivery_rejected(user, id, selected, socket, "Build intervals", false)
  end

  test "bootstrap delivery rejects when the presentation current policy slot changed", %{
    conn: _conn
  } do
    {user, now, expected_slot, id, _req, socket, selected, _alternative} =
      committed_pending_bootstrap()

    future_now = DateTime.add(now, 7 * 86_400, :second)
    {:ok, next_slot} = Policy.required_slot(user, future_now)

    refute {next_slot.slot_key, next_slot.slot_date} ==
             {expected_slot.slot_key, expected_slot.slot_date}

    socket = Phoenix.Component.assign(socket, home_now: fn -> future_now end)

    assert_delivery_rejected(user, id, selected, socket, "Build intervals", false)
  end

  test "bootstrap delivery rejects a competing started session after commit", %{conn: _conn} do
    {user, _now, _expected_slot, id, _req, socket, selected, alternative} =
      committed_pending_bootstrap()

    assert {:ok, _selected_plan} = Workouts.verify_home_selection(user, selected)
    assert {:ok, _session} = Workouts.start_plan(user, alternative.id, Ecto.UUID.generate())

    assert_delivery_rejected(user, id, selected, socket, "Build intervals", true)
  end

  test "returning user mount retains an intentional built-in pin without a provider call", %{
    conn: _conn
  } do
    user = returning_user()
    now = DateTime.utc_now(:second)
    {:ok, slot} = Policy.required_slot(user, now)

    {:ok, pinned} =
      Workouts.ensure_recommendation(user, %{slot_key: slot.slot_key, slot_date: slot.slot_date})

    socket = mounted_socket(user, now)

    refute socket.assigns.bootstrap?
    assert socket.assigns.home_selection.recommendation_id == pinned.id
    assert socket.assigns.home_selection.plan.id == pinned.selected_workout_plan_id
    refute_received :unexpected_provider
  end

  test "returning user mount preserves owned draft content without a provider call", %{
    conn: _conn
  } do
    user = returning_user()
    draft = workout_plan_draft_fixture(user, %{name: "Keep draft"})

    assert_returning_mount_preserves_plan(user, draft, :draft)
  end

  test "returning user mount preserves owned published content without a provider call", %{
    conn: _conn
  } do
    user = returning_user()
    published = plan_fixture(user, %{name: "Keep published"})

    assert_returning_mount_preserves_plan(user, published, :published)
  end

  test "returning user mount preserves owned archived content without a provider call", %{
    conn: _conn
  } do
    user = returning_user()
    draft = workout_plan_draft_fixture(user, %{name: "Keep archived"})
    {:ok, published} = Workouts.publish_draft(user, draft.id)
    {:ok, archived} = Workouts.archive_plan(user, published.id)

    assert_returning_mount_preserves_plan(user, archived, :archived)
  end

  test "returning user mount keeps historical-only recommendation on the existing path", %{
    conn: _conn
  } do
    user = returning_user()
    now = DateTime.utc_now(:second)
    {:ok, slot} = Policy.required_slot(user, now)

    {:ok, historical} =
      Workouts.ensure_recommendation(user, %{
        slot_key: "historical:" <> slot.slot_key,
        slot_date: Date.add(slot.slot_date, -7)
      })

    socket = mounted_socket(user, now)

    refute socket.assigns.bootstrap?

    assert Date.compare(Repo.get!(CoachRecommendation, historical.id).slot_date, slot.slot_date) ==
             :lt

    assert socket.assigns.home_selection != nil
    refute_received :unexpected_provider
  end

  test "returning user mount keeps historical-only manual session on the existing path", %{
    conn: _conn
  } do
    user = returning_user()
    now = DateTime.utc_now(:second)
    {:ok, slot} = Policy.required_slot(user, now)
    completed_at = DateTime.add(now, -86_400, :second)

    session =
      Repo.insert!(%WorkoutSession{
        user_id: user.id,
        state: :completed,
        source_kind: :manual,
        capture_mode: :logged,
        burpee_type: :six_count,
        completed_at: completed_at,
        burpee_count_actual: 25,
        duration_sec_actual: 120
      })

    socket = mounted_socket(user, now)

    refute socket.assigns.bootstrap?
    assert Repo.get!(WorkoutSession, session.id).completed_at == completed_at
    assert Date.compare(DateTime.to_date(completed_at), slot.slot_date) == :lt
    assert socket.assigns.home_selection != nil
    refute_received :unexpected_provider
  end

  test "returning user mount keeps historical-only built-in session on the existing path", %{
    conn: _conn
  } do
    user = returning_user()
    built_in = Enum.find(Workouts.list_library(user), &(&1.origin == :built_in))
    session = session_from_plan_fixture(user, built_in)
    completed_at = session.completed_at
    now = DateTime.add(completed_at, 86_400, :second)
    {:ok, slot} = Policy.required_slot(user, now)

    assert_historical_session_mount(user, now, slot, session, :plan, completed_at)
  end

  test "returning user mount keeps historical-only video session on the existing path", %{
    conn: _conn
  } do
    user = returning_user()
    video = video_fixture(%{burpee_count: 60})
    {:ok, started} = Workouts.start_video(user, video.id, Ecto.UUID.generate())

    {:ok, session} =
      Workouts.complete_session(
        user,
        started.id,
        %{"burpee_count_actual" => 25, "duration_sec_actual" => 120},
        :timed
      )

    completed_at = session.completed_at
    now = DateTime.add(completed_at, 86_400, :second)
    {:ok, slot} = Policy.required_slot(user, now)

    assert_historical_session_mount(user, now, slot, session, :video, completed_at)
  end

  defp committed_pending_bootstrap do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    now = DateTime.utc_now(:second)
    {:ok, expected_slot} = Policy.required_slot(user, now)
    id = make_ref()
    req = immediate_req(definition("Bootstrap delivery"))
    socket = pending_bootstrap_socket(user, now, expected_slot, id, "Build intervals")
    assert Workouts.home_entry_state(user, expected_slot) == {:ok, :bootstrap}

    assert {:ok, selected} =
             Coach.bootstrap_home_draft(user, expected_slot, "Build intervals", opts(req))

    alternative = plan_fixture(user)
    assert %Req.Request{} = req
    {user, now, expected_slot, id, req, socket, selected, alternative}
  end

  defp pending_bootstrap_socket(user, now, expected_slot, id, prompt) do
    socket = mounted_socket(user, now)
    assert socket.assigns.home_selection == nil
    assert socket.assigns.slot == expected_slot

    Phoenix.Component.assign(socket,
      bootstrap?: true,
      busy?: true,
      bootstrap_id: id,
      bootstrap_prompt: prompt,
      bootstrap_slot: expected_slot,
      bootstrap_form: Phoenix.Component.to_form(%{"prompt" => prompt}, as: :home_bootstrap)
    )
  end

  defp assert_delivery_rejected(user, id, selected, socket, prompt, started?) do
    assert {:noreply, delivered} =
             OverviewLive.handle_async({:home_bootstrap, id}, {:ok, {:ok, selected}}, socket)

    assert delivered.assigns.bootstrap_prompt == prompt
    assert delivered.assigns.bootstrap_form.params["prompt"] == prompt
    refute delivered.assigns.busy?
    assert delivered.assigns.history_open? == socket.assigns.history_open?

    if started? do
      assert %{state: :started} = Workouts.current_started_session(user)
    else
      assert Workouts.current_started_session(user) == nil
    end

    html = rendered(delivered)
    assert selector?(html, "#home-bootstrap-form")
    assert selector?(html, "#home-bootstrap-prompt[name='home_bootstrap[prompt]']")
    refute selector?(html, "#home-bootstrap-loading")
    refute selector?(html, "#home-summary")
    refute selector?(html, "#home-action")
  end

  defp assert_historical_session_mount(user, now, slot, session, source_kind, completed_at) do
    assert Repo.aggregate(from(plan in WorkoutPlan, where: plan.user_id == ^user.id), :count) == 0

    assert Repo.aggregate(
             from(recommendation in CoachRecommendation,
               where: recommendation.user_id == ^user.id
             ),
             :count
           ) == 0

    socket = mounted_socket(user, now)

    refute socket.assigns.bootstrap?

    assert %WorkoutSession{source_kind: ^source_kind, completed_at: ^completed_at} =
             Repo.get!(WorkoutSession, session.id)

    assert Date.compare(DateTime.to_date(completed_at), slot.slot_date) == :lt
    assert socket.assigns.home_selection != nil
    refute_received :unexpected_provider
  end

  defp returning_user do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    user
  end

  defp assert_returning_mount_preserves_plan(user, plan, state) do
    now = DateTime.utc_now(:second)
    before = Repo.get!(WorkoutPlan, plan.id)
    socket = mounted_socket(user, now)
    after_mount = Repo.get!(WorkoutPlan, plan.id)

    refute socket.assigns.bootstrap?
    assert after_mount.state == state
    assert after_mount.name == before.name
    assert after_mount.definition_json == before.definition_json
    assert socket.assigns.home_selection != nil
    refute_received :unexpected_provider
  end

  defp mounted_socket(user, now) do
    socket = %Phoenix.LiveView.Socket{
      endpoint: BurpeeTrainerWeb.Endpoint,
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{
        __changed__: %{},
        current_user: user,
        current_level: :level_1a,
        flash: %{},
        home_now: fn -> now end
      }
    }

    {:ok, socket} = OverviewLive.mount(%{}, %{}, socket)
    socket
  end

  defp immediate_req(workout_definition) do
    Req.new(
      adapter: fn request ->
        {request, %Req.Response{status: 200, body: provider_body(workout_definition)}}
      end
    )
  end

  defp opts(req), do: [req: req, config: provider_config()]

  defp provider_config,
    do: [
      enabled: true,
      url: "https://provider.test/v1/chat/completions",
      api_key: "test-secret",
      model: "test/model",
      timeout_ms: 12_345
    ]

  defp provider_body(workout_definition),
    do:
      Jason.encode!(%{
        "choices" => [%{"message" => %{"content" => Jason.encode!(workout_definition)}}]
      })

  defp definition(name),
    do: %{
      "version" => 1,
      "name" => name,
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "even",
      "events" => [
        %{"kind" => "work", "reps" => 10, "sec_per_rep" => 12.0, "sec_per_burpee" => 12.0}
      ],
      "rationale" => "bootstrap fixture"
    }

  defp rendered(socket), do: render_component(&OverviewLive.render/1, socket.assigns)

  defp selector?(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.any?()
end
