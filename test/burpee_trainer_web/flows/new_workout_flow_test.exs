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

  test "New is one form in place of Home, and back leaves it", %{view: view} do
    open_new(view)

    assert has_element?(view, "#home-studio h1#home-authoring-heading", "New workout")
    refute has_element?(view, "#home-workout-hero, #home-chat-dock, #studio-thread")
    # One way out and one way on, both at the foot; nothing in the bar above.
    assert has_element?(view, "#studio-new-form .studio-foot #studio-create[aria-label=Create]")

    assert has_element?(
             view,
             "#studio-new-form .studio-foot #home-request-abort[aria-label=Close]"
           )

    refute has_element?(view, ".studio-header button")

    view |> element("#home-request-abort") |> render_click()
    refute has_element?(view, "#home-studio")
    assert hero_focus_target(view) == "#home-summary"
  end

  test "the form opens on a standard session; values are typed or stepped, and say what they come to",
       %{view: view} do
    open_new(view)

    assert shown(view, "duration") == "20"
    assert has_element?(view, "#studio-duration-hint", "left this week")
    # With no history, the next level's landmark scaled to the duration, at a mid pace.
    assert shown(view, "reps") == "50"
    assert shown(view, "pace") == "4.5"
    # What it makes: 50 reps across 20 minutes on an even beat.
    assert has_element?(view, "#studio-shape", "One rep every 24 s, all the way")

    view |> element("#studio-duration-up") |> render_click()
    assert shown(view, "duration") == "25"
    view |> element("#studio-duration-down") |> render_click()
    assert shown(view, "duration") == "20"

    # From fifty, reps step by ten.
    view |> element("#studio-reps-up") |> render_click()
    assert shown(view, "reps") == "60"
    assert has_element?(view, "#studio-shape", "One rep every 20 s, all the way")
    view |> element("#studio-pace-up") |> render_click()
    assert shown(view, "pace") == "5.0"

    fill(view, "reps", "150")
    assert shown(view, "reps") == "150"
    # A value that is not a number is not taken.
    fill(view, "reps", "lots")
    assert shown(view, "reps") == "150"
  end

  test "New is sent as it is, a proposal comes back, and Run saves, selects and starts it",
       %{view: view, user: user, selected: selected, conn: conn} do
    layout = layout([[{50, 5.0, 5.0}, {50, 5.0, 5.0}]], "Independent new workout")

    counter = fake_authoring_provider(%{"workout_layout" => layout})
    count = Repo.aggregate(WorkoutPlan, :count)

    walk(view, style: "unbroken", reps: 100, minutes: 20, max_set: "50", pace_ups: 1)
    create(view)
    render_async(view, 2_000)

    assert has_element?(view, "#home-edit-review #studio-proposal", "Independent new workout")

    assert has_element?(
             view,
             "#home-edit-review #home-chat-actions #home-request-run[aria-label=Run]"
           )

    # The camera and warmup choices are Home's; the chat has none of its own.
    refute has_element?(view, "#home-studio #home-start-camera, #home-studio #home-start-warmup")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    assert Agent.get(counter, & &1.calls) == ["workout_layout"]

    view |> element("#home-request-run") |> render_click()
    {path, _flash} = assert_redirect(view, 2_000)
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
    assert has_element?(history, "#home-history-point-#{session.id}")
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
    assert has_element?(view, "#home-inspection .home-prescription-rest", "1:00")
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
    assert has_element?(view, "#home-inspection .home-prescription-rest", "1:00")

    view |> element("#home-request-run") |> render_click()
    assert_redirect(view, 2_000)

    [saved] =
      Enum.filter(Workouts.list_library(Scope.for_user(user)), &(&1.name == "Minute blocks"))

    assert saved.target_duration_sec == 1200
    assert {:ok, definition} = WorkoutDefinition.new(saved.definition_json)

    assert {660_000_000, 60_000_000} in WorkoutRequest.rest_timeline(definition.events)
    assert {1_080_000_000, 40_000_000} in WorkoutRequest.rest_timeline(definition.events)
    assert Agent.get(counter, & &1.calls) == ["workout_request", "workout_layout"]

    # Run saved it as today's workout in place of the one before.
    assert {:ok, now} = Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))
    assert now.plan.id == saved.id
    refute now.plan.id == selected.plan.id
  end

  test "an unbroken workout can limit the reps in a set, and the coach is told", %{view: view} do
    quarters = List.duplicate({25, 5.0, 5.0}, 4)
    counter = fake_authoring_provider(%{"workout_layout" => layout([quarters], "Quarter sets")})

    walk(view, style: "unbroken", reps: 100, minutes: 20, max_set: 25, pace_ups: 1)
    assert shown(view, "sets") == "25"
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
    # The form is back, as it was, to change.
    assert shown(view, "sets") == "25"
  end

  test "an even beat has no set size to ask; unbroken sets say how they fall", %{view: view} do
    open_new(view)
    fill(view, "pacing_style", "even")
    refute has_element?(view, "#studio-sets")
    fill(view, "pacing_style", "unbroken")
    assert has_element?(view, "#studio-sets[placeholder='No limit']")
    fill(view, "sets", "10")
    # 50 reps at 4.5 s in sets of 10: what movement leaves of 20 minutes, shared between them.
    assert has_element?(view, "#studio-shape", "5 sets of 10 · 4:04 rest")
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
    assert has_element?(view, "#studio-note[name='new[note]'][maxlength='300']")
    request(view, "slow and steady")

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
    fill(view, "duration", "5")
    # 300 s at 4.5 s a rep holds 66 reps; the last step stops there, short of a whole one.
    press_while_possible(view, "#studio-reps-up")
    assert shown(view, "reps") == "66"
    assert has_element?(view, "#studio-reps-up[disabled]")
    assert Agent.get(counter, & &1.calls) == []
  end

  test "a value typed and sent straight away is the one used", %{view: view} do
    halves = List.duplicate({15, 4.5, 4.5}, 2)
    fake_authoring_provider(%{"workout_layout" => layout([halves], "Thirty")})

    open_new(view)
    # Enter in a field sends the form before the field's own change does.
    view |> form("#studio-new-form", new: %{reps: "30"}) |> render_submit()
    render_async(view, 2_000)

    assert has_element?(view, "#studio-proposal .studio-chip", "30 reps")
  end

  test "the coach offers its guesses at the next ask; a tap sends one as if typed", %{view: view} do
    halves = List.duplicate({15, 4.5, 4.5}, 2)

    layout =
      [halves]
      |> layout("Thirty")
      |> Map.put("suggestions", ["Even out the rests", "Add a 1-minute rest at 10:00"])

    counter =
      fake_authoring_provider(%{
        "workout_layout" => layout,
        "workout_request" => %{
          "burpee_type" => "six_count",
          "target_reps" => 30,
          "target_duration_sec" => 1_200,
          "pacing_style" => "unbroken",
          "recovery" => "optional",
          "timed_rests" => [],
          "requested_pace_sec" => 4.5,
          "set_reps" => []
        }
      })

    open_new(view)
    view |> form("#studio-new-form", new: %{reps: "30"}) |> render_submit()
    render_async(view, 2_000)

    assert has_element?(view, "#studio-suggestions[aria-label='Suggested changes']")
    assert has_element?(view, "#studio-suggestion-0", "Even out the rests")
    assert has_element?(view, "#studio-suggestion-1", "Add a 1-minute rest at 10:00")

    view |> element("#studio-suggestion-0") |> render_click()
    render_async(view, 2_000)

    # It went to the coach as the follow-up, and reads in the thread as what was asked.
    assert Agent.get(counter, & &1.bodies) |> List.last() =~ "Even out the rests"
    assert has_element?(view, "#studio-thread", "Even out the rests")
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
