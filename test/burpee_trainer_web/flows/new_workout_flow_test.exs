defmodule BurpeeTrainerWeb.Flows.NewWorkoutFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  import BurpeeTrainerWeb.StudioHelpers

  alias BurpeeTrainer.{Accounts, Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Policy, WorkoutRequest}
  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    {:ok, selected} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, view, _} = live(conn, ~p"/")
    %{conn: conn, view: view, user: user, selected: selected}
  end

  test "New asks one question at a time; back is one step back and leaves from the first",
       %{view: view} do
    open_new(view)

    # The studio takes Home's place and shows only the question being asked.
    assert has_element?(view, "#home-studio h1#home-authoring-heading", "New workout")
    assert has_element?(view, "#studio-step", "Which burpee?")
    assert has_element?(view, "ol[aria-label='Question 1 of 5']")
    refute has_element?(view, "#home-workout-hero, #home-chat-dock, #studio-thread")
    # Back from the first question leaves; there is no separate close.
    assert has_element?(view, "#home-request-abort[aria-label='Cancel new workout']")
    refute has_element?(view, "#studio-back, .studio-close")

    # A tap on a choice answers it; no Next, and the answered question is gone.
    view |> element("#home-pill-burpee_type-navy_seal") |> render_click()
    assert has_element?(view, "#studio-step", "How should the sets go?")
    refute has_element?(view, "#home-pill-burpee_type-six_count")
    refute has_element?(view, "#studio-next")
    assert has_element?(view, "ol[aria-label='Question 2 of 5']")

    view |> element("#studio-back") |> render_click()
    assert has_element?(view, "#studio-step", "Which burpee?")

    view |> element("#home-request-abort") |> render_click()
    refute has_element?(view, "#home-studio")
    assert hero_focus_target(view) == "#home-summary"
  end

  test "each pill carries its value, since the client sends a button's own value", %{view: view} do
    open_new(view)

    for {field, value} <- [{"burpee_type", "six_count"}, {"burpee_type", "navy_seal"}] do
      assert has_element?(view, "#home-pill-#{field}-#{value}[value=#{value}]")
    end

    view |> element("#home-pill-burpee_type-six_count") |> render_click()

    for value <- ~w[even unbroken] do
      assert has_element?(view, "#home-pill-pacing_style-#{value}[value=#{value}]")
    end
  end

  test "duration starts at a standard session and moves by five, reps by five, pace by half a second",
       %{view: view} do
    open_new(view)
    view |> element("#home-pill-burpee_type-six_count") |> render_click()
    view |> element("#home-pill-pacing_style-even") |> render_click()

    assert has_element?(view, "#studio-step", "How long?")
    assert has_element?(view, "#studio-duration-value", "20")
    assert has_element?(view, ".studio-step-hint", "left this week")

    view |> element("#studio-duration-up") |> render_click()
    assert has_element?(view, "#studio-duration-value", "25")
    view |> element("#studio-duration-down") |> render_click()
    view |> element("#studio-duration-down") |> render_click()
    assert has_element?(view, "#studio-duration-value", "15")
    # The same step the swipe takes.
    render_hook(view, "step_workout_value", %{"field" => "duration", "dir" => "up"})
    assert has_element?(view, "#studio-duration-value", "20")

    view |> element("#studio-next") |> render_click()
    assert has_element?(view, "#studio-step", "How many reps?")
    # With no history, the next level's landmark scaled to the duration.
    assert has_element?(view, "#studio-reps-value", "50")
    # What it comes to: 50 reps at 4.5 s is 3:45 moving, the rest of the 20 minutes recovery.
    assert has_element?(view, ".studio-step-hint", "3:45 moving · 16:15 recovering")
    view |> element("#studio-reps-up") |> render_click()
    assert has_element?(view, "#studio-reps-value", "55")
    assert has_element?(view, ".studio-step-hint", "4:08 moving · 15:52 recovering")

    view |> element("#studio-next") |> render_click()
    assert has_element?(view, "#studio-step", "How fast is each rep?")
    assert has_element?(view, "#studio-pace-value", "4.5")
    view |> element("#studio-pace-up") |> render_click()
    assert has_element?(view, "#studio-pace-value", "5.0")
    assert has_element?(view, ".studio-step-hint", "4:35 moving · 15:25 recovering")

    view |> element("#studio-next") |> render_click()

    # The last screen is what was chosen: send it as it is, or add a request.
    assert has_element?(view, "#studio-step", "Ready?")
    assert has_element?(view, "#studio-row-duration .studio-summary-value", "20 min")
    assert has_element?(view, "#studio-row-pace .studio-summary-value", "5.0 s per rep")
    assert has_element?(view, "#studio-create", "Create workout")
    refute has_element?(view, "#home-chat-dock")

    # Adding a request opens the chat, empty: it is for a request only, not the answers again.
    view |> element("#studio-add-request") |> render_click()
    assert has_element?(view, "#studio-thread", "Anything else")
    assert has_element?(view, "#home-edit-instruction[placeholder='Additional request']")

    assert view
           |> element("#home-edit-instruction")
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.text()
           |> String.trim() == ""

    # It may be sent without a word, so Send is ready.
    assert has_element?(view, "#home-chat-dock #home-edit-send.composer-send-ready")

    # Back is one step back: to what was chosen.
    view |> element("#studio-back") |> render_click()
    assert has_element?(view, "#studio-create")
  end

  test "an earlier answer can be changed, and what followed it is suggested again", %{view: view} do
    walk(view)
    assert has_element?(view, "#studio-request", "20 min")

    view |> element("#studio-row-duration") |> render_click()
    assert has_element?(view, "#studio-step", "How long?")
    refute has_element?(view, "#home-chat-dock")

    view |> element("#studio-duration-down") |> render_click()
    view |> element("#studio-next") |> render_click()
    assert has_element?(view, "#studio-reps-value", "40")
  end

  test "New is sent as it is, a proposal comes back, and Run saves, selects and starts it",
       %{view: view, user: user, selected: selected, conn: conn} do
    layout = layout([[{50, 5.0, 5.0}, {50, 5.0, 5.0}]], "Independent new workout")

    counter = fake_authoring_provider(%{"workout_layout" => layout})
    count = Repo.aggregate(WorkoutPlan, :count)

    walk(view, style: "unbroken", reps: 100, minutes: 20, pace_ups: 1)
    create(view)
    render_async(view, 2_000)

    assert has_element?(view, "#home-edit-review #studio-proposal", "Independent new workout")
    assert has_element?(view, "#home-edit-review #home-chat-actions #home-request-run", "Run")
    # Run starts it, so the device's start toggles sit beside it.
    assert has_element?(view, "#home-chat-actions #home-start-camera")
    assert has_element?(view, "#home-chat-actions #home-start-warmup")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    assert Agent.get(counter, & &1.calls) == ["workout_layout"]

    view |> element("#home-request-run") |> render_click()
    render_async(view, 2_000)
    {path, _flash} = assert_redirect(view)
    assert "/session/" <> id = path

    [saved] =
      Enum.filter(Workouts.list_library(Scope.for_user(user)), &(&1.name == layout["name"]))

    assert saved.state == :published
    assert Repo.aggregate(WorkoutPlan, :count) == count + 1

    # It is today's workout, and the session started is its own.
    assert {:ok, chosen} =
             Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))

    assert chosen.plan.id == saved.id
    refute chosen.plan.id == selected.plan.id
    assert Agent.get(counter, & &1.calls) == ["workout_layout"]

    session = Repo.get!(WorkoutSession, String.to_integer(id))
    assert session.plan_id == saved.id
    {:ok, runner, _} = live(conn, ~p"/session/#{session.id}")

    render_hook(runner, "save_session", %{
      "workout_session" => %{
        "burpee_count_actual" => 100,
        "duration_sec_actual" => 1200,
        "client_session_id" => session.client_session_id
      },
      "tracking" => %{"enabled" => false, "trust" => "disabled", "cadence_ms" => []}
    })

    assert_reply(runner, %{status: "ok"})
    {:ok, history, _} = live(conn, ~p"/progress")
    assert has_element?(history, "#home-history-session-#{session.id}")
  end

  test "New fits recorded fixed pauses exactly before publishing without selecting", %{
    view: view,
    user: user,
    selected: selected
  } do
    eight = {8, 5.0, 5.0}
    six = {6, 5.0, 5.0}

    counter =
      fake_authoring_provider(%{
        "workout_request" => %{
          "burpee_type" => "six_count",
          "target_reps" => 140,
          "target_duration_sec" => 1200,
          "pacing_style" => "unbroken",
          "recovery" => "required",
          "timed_rests" => [
            %{"start_sec" => 660, "duration_sec" => 60},
            %{"start_sec" => 1080, "duration_sec" => 40}
          ],
          "requested_pace_sec" => 5.0,
          "set_reps" => []
        },
        "workout_layout" =>
          layout(
            [List.duplicate(eight, 10), List.duplicate(eight, 6), [six, six]],
            "Minute blocks"
          )
      })

    walk(view, style: "unbroken", reps: 140, minutes: 20, pace_ups: 1)

    request(view, "A minute's break at 11:00 and 40 seconds at 18:00")

    render_async(view, 2_000)
    assert Agent.get(counter, & &1.calls) == ["workout_request", "workout_layout"]
    assert has_element?(view, "#studio-proposal #home-inspection")
    assert has_element?(view, "#home-inspection .home-prescription-rest", "60s")
    assert has_element?(view, "#home-inspection .home-prescription-rest", "40s")
    assert has_element?(view, "#home-edit-review-pauses", "Pauses: 60s at 11:00")
    assert has_element?(view, "#home-edit-review-pauses", "40s at 18:00")

    first_group =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#studio-proposal .home-group-toggle")

    [group_id | _] = LazyHTML.attribute(first_group, "id")
    view |> element("##{group_id}") |> render_click()
    assert has_element?(view, "##{group_id}[aria-expanded=true]")
    assert has_element?(view, "#home-inspection .home-prescription-rest", "60s")

    view |> element("#home-request-save") |> render_click()
    render_async(view, 2_000)
    assert has_element?(view, "#home-new-saved", "Minute blocks")

    [saved] =
      Enum.filter(Workouts.list_library(Scope.for_user(user)), &(&1.name == "Minute blocks"))

    assert saved.target_duration_sec == 1200
    assert {:ok, definition} = WorkoutDefinition.new(saved.definition_json)

    assert {660_000_000, 60_000_000} in WorkoutRequest.rest_timeline(definition.events)
    assert {1_080_000_000, 40_000_000} in WorkoutRequest.rest_timeline(definition.events)
    assert Agent.get(counter, & &1.calls) == ["workout_request", "workout_layout"]

    assert {:ok, unchanged} =
             Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))

    assert unchanged.plan.id == selected.plan.id
  end

  test "an unbroken workout can limit the reps in a set, and the coach is told", %{view: view} do
    quarters = List.duplicate({25, 5.0, 5.0}, 4)
    counter = fake_authoring_provider(%{"workout_layout" => layout([quarters], "Quarter sets")})

    walk(view, style: "unbroken", reps: 100, minutes: 20, max_set: 25, pace_ups: 1)
    assert has_element?(view, "#studio-row-sets .studio-summary-value", "Up to 25")
    create(view)
    render_async(view, 2_000)

    assert has_element?(view, "#studio-proposal", "Quarter sets")
    assert [body] = Agent.get(counter, & &1.bodies)
    assert body =~ "No set may have more than 25 reps"
  end

  test "a layout that goes past the limit is refused after its one correction", %{view: view} do
    halves = List.duplicate({50, 5.0, 5.0}, 2)
    counter = fake_authoring_provider(%{"workout_layout" => layout([halves], "Half sets")})

    walk(view, style: "unbroken", reps: 100, minutes: 20, max_set: 25, pace_ups: 1)
    create(view)
    render_async(view, 2_000)

    assert Agent.get(counter, & &1.calls) == ["workout_layout", "workout_layout"]
    refute has_element?(view, "#home-request-run")
    assert has_element?(view, "#home-adjustment-error")
    # The choices are still there to change.
    assert has_element?(view, "#studio-row-sets .studio-summary-value", "Up to 25")
  end

  test "an even beat has no set size to ask", %{view: view} do
    open_new(view)
    view |> element("#home-pill-burpee_type-six_count") |> render_click()
    view |> element("#home-pill-pacing_style-even") |> render_click()
    view |> element("#studio-next") |> render_click()
    view |> element("#studio-next") |> render_click()
    assert has_element?(view, "#studio-step", "How fast is each rep?")
    assert has_element?(view, "ol[aria-label='Question 5 of 5']")
  end

  defp layout(phases, name) do
    %{
      "name" => name,
      "rationale" => "Recorded layout response.",
      "phases" =>
        Enum.map(phases, fn sets ->
          %{
            "sets" =>
              Enum.map(sets, fn {reps, cadence, active} ->
                %{"reps" => reps, "sec_per_rep" => cadence, "sec_per_burpee" => active}
              end),
            "rests" => List.duplicate(%{"share" => 1}, length(sets) - 1)
          }
        end)
    }
  end

  test "the message reaches the coach alongside the chosen values", %{view: view} do
    counter =
      fake_authoring_provider(%{
        "workout_request" => %{
          "burpee_type" => "six_count",
          "target_reps" => 10,
          "target_duration_sec" => 300,
          "pacing_style" => "unbroken",
          "recovery" => "required",
          "timed_rests" => [],
          "requested_pace_sec" => 4.5,
          "set_reps" => []
        },
        "workout_layout" => layout([[{5, 4.5, 4.5}, {5, 4.5, 4.5}]], "Noted new workout")
      })

    walk(view, style: "unbroken", reps: 10, minutes: 5)
    view |> element("#studio-add-request") |> render_click()

    assert has_element?(
             view,
             "#home-edit-form textarea[name='home_adjustment[instruction]'][maxlength='300']"
           )

    view
    |> form("#home-edit-form", home_adjustment: %{instruction: "slow and steady"})
    |> render_submit()

    render_async(view, 2_000)
    assert has_element?(view, "#home-edit-review #studio-proposal")
    # The coach reads the note for sets and pauses, then plans with it.
    assert [extraction, layout] = Agent.get(counter, & &1.bodies)

    for body <- [extraction, layout] do
      assert body
             |> Jason.decode!()
             |> Map.fetch!("messages")
             |> Enum.any?(&(&1["content"] =~ "slow and steady"))
    end
  end

  test "reps stop where the movement alone would no longer fit the duration", %{view: view} do
    counter = fake_authoring_provider(%{})
    open_new(view)
    view |> element("#home-pill-burpee_type-six_count") |> render_click()
    view |> element("#home-pill-pacing_style-unbroken") |> render_click()
    step_to(view, "duration", 5)
    view |> element("#studio-next") |> render_click()
    # 300 s at 4.5 s a rep holds 66 reps; in steps of five from 15, 65 is the last.
    press_while_possible(view, "#studio-reps-up")
    assert has_element?(view, "#studio-reps-value", "65")
    assert has_element?(view, "#studio-reps-up[disabled]")

    view |> element("#studio-next") |> render_click()
    assert Agent.get(counter, & &1.calls) == []
  end

  defp fake_authoring_provider(responses) do
    original = Application.fetch_env!(:burpee_trainer, :llm_provider)
    on_exit(fn -> Application.put_env(:burpee_trainer, :llm_provider, original) end)
    counter = start_supervised!({Agent, fn -> %{responses: responses, calls: []} end})
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)

    start_supervised!(
      {Bandit,
       plug: {BurpeeTrainer.TestAuthoringProviderPlug, counter: counter},
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false}
    )

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "http://127.0.0.1:#{port}/chat/completions",
      api_key: "test-key",
      model: "test-model",
      timeout_ms: 20_000
    )

    counter
  end

  defp selected_slot(user) do
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    slot
  end

  defp hero_focus_target(view) do
    [commands] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-workout-hero")
      |> LazyHTML.attribute("phx-mounted")

    [["focus", %{"to" => target}]] = Jason.decode!(commands)
    target
  end
end
