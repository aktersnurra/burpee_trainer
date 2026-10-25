defmodule BurpeeTrainerWeb.Flows.NewWorkoutFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

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

  test "New takes the workout's place under one heading, and abort brings the workout back",
       %{view: view} do
    view |> element("#home-summary") |> render_click()
    view |> element("#home-new-workout") |> render_click()

    assert has_element?(view, "h1#home-authoring-heading", "New workout")
    refute has_element?(view, "#home-workout-hero")
    refute has_element?(view, "#home-new-form h2")

    assert has_element?(view, ".home-new-note #home-request-abort[aria-label]")
    assert has_element?(view, ".home-new-note #home-new-review[aria-label='Review workout']")

    view |> element("#home-request-abort") |> render_click()
    refute has_element?(view, "#home-authoring-heading")
    # The workout mounts again and takes focus once the patch has landed.
    assert hero_focus_target(view) == "#home-summary"
  end

  test "New starts with the current workout's targets without pinning its movement pace", %{
    conn: conn,
    user: user,
    selected: selected
  } do
    plan =
      plan_fixture(user, %{burpee_type: "navy_seal", target_reps: 60, target_duration_sec: 1200})

    {:ok, chosen} = Workouts.select_home_workout(Scope.for_user(user), selected, plan.id)
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#home-summary") |> render_click()
    view |> element("#home-new-workout") |> render_click()

    assert has_element?(view, "#home-pill-burpee_type-navy_seal[aria-pressed=true]")
    assert has_element?(view, "#home-new-reps[value='60']")
    assert has_element?(view, "#home_workout_duration[value='20:00']")
    refute has_element?(view, "#home_workout_pace[value]:not([value=''])")

    assert {:ok, ^chosen} =
             Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))
  end

  test "New fields name their units beside the value", %{view: view} do
    view |> element("#home-summary") |> render_click()
    view |> element("#home-new-workout") |> render_click()

    for {id, unit} <- [
          {"home-new-reps", "reps"},
          {"home_workout_duration", "min"},
          {"home_workout_pace", "s per rep"}
        ] do
      assert has_element?(view, "label[for=#{id}] .input-unit", unit)
    end

    for {id, label} <- [{"home_workout_pace", "Pace"}, {"home_workout_note", "Anything else"}] do
      assert view |> element("label[for=#{id}] .label") |> render() =~ ">#{label}<"
    end

    # Sets and pauses are said in plain words in the note; there is no syntax to learn.
    refute has_element?(view, "#home_workout_sets, #home_workout_rests")
    assert has_element?(view, "#home_workout_note[placeholder^='Anything else?']")
  end

  test "the computed work and recovery is a caption under Duration, with the timing rule", %{
    view: view
  } do
    view |> element("#home-summary") |> render_click()
    view |> element("#home-new-workout") |> render_click()

    ids =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(
        "#home-new-form input:not([type=hidden]), #home-new-form textarea, #home-workout-budget"
      )
      |> LazyHTML.attribute("id")

    assert Enum.take(ids, 3) == ["home-new-reps", "home_workout_duration", "home-workout-budget"]
    refute has_element?(view, "#home-workout-budget", "Timing")
    refute has_element?(view, "#home-request-timing")
  end

  test "today's workout fades out before New comes in, and back in on Cancel", %{view: view} do
    view |> element("#home-summary") |> render_click()
    hero = view |> element("#home-workout-hero") |> render()
    # The fade runs on the click, so the form waits for it instead of landing beside it.
    refute hero =~ ~s(phx-remove=)
    assert view |> element("#home-new-workout") |> render() =~ "home-leaving"
    # Edit keeps the workout in view, so it does not fade it.
    refute view |> element("#home-edit-workout") |> render() =~ "home-leaving"

    view |> element("#home-new-workout") |> render_click()
    assert has_element?(view, "#home-authoring-heading.home-enter")
    assert has_element?(view, "#home-new-form.home-enter")

    view |> element("#home-request-abort") |> render_click()
    assert view |> element("#home-workout-hero") |> render() =~ "home-enter"
  end

  test "the selected pill follows every switch", %{view: view} do
    view |> element("#home-summary") |> render_click()
    view |> element("#home-new-workout") |> render_click()

    # LiveView's client sends a clicked button's own value as "value", over phx-value-value,
    # so each pill must carry its value or the browser sends "".
    for field <- ~w[burpee_type pacing_style],
        value <- ~w[six_count navy_seal even unbroken],
        has_element?(view, "#home-pill-#{field}-#{value}") do
      assert has_element?(view, "#home-pill-#{field}-#{value}[value=#{value}]")
    end

    for type <- ~w[navy_seal six_count navy_seal six_count] do
      view |> element("#home-pill-burpee_type-#{type}") |> render_click()
      assert has_element?(view, "#home-pill-burpee_type-#{type}[aria-pressed=true]")

      assert has_element?(
               view,
               "#home-new-form input[type=hidden][name='home_workout[burpee_type]'][value=#{type}]"
             )
    end
  end

  test "New reviews without a plan, Use saves and selects, then Start completes into History",
       %{
         view: view,
         user: user,
         selected: selected,
         conn: conn
       } do
    layout = layout([[{10, 12.0, 12.0}]], "Independent new workout")

    counter = fake_authoring_provider(%{"workout_layout" => layout})
    view |> element("#home-summary") |> render_click()
    view |> element("#home-new-workout") |> render_click()
    count = Repo.aggregate(WorkoutPlan, :count)
    view |> element("#home-pill-pacing_style-even") |> render_click()
    view |> form("#home-new-form", home_workout: %{reps: 10, duration: "2:00"}) |> render_submit()
    render_async(view)

    assert has_element?(view, "#home-new-form[data-stage=review]")
    assert has_element?(view, "#home-new-reps[disabled][value='10']")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    assert Agent.get(counter, & &1.calls) == ["workout_layout"]

    view |> element("#home-request-confirm") |> render_click()
    render_async(view)
    refute has_element?(view, "#home-new-saved")
    assert has_element?(view, "#home-action")
    assert Repo.aggregate(WorkoutSession, :count) == 0

    [saved] =
      Enum.filter(Workouts.list_library(Scope.for_user(user)), &(&1.name == layout["name"]))

    assert saved.state == :published
    assert Repo.aggregate(WorkoutPlan, :count) == count + 1

    assert {:ok, unchanged} =
             Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))

    assert unchanged.plan.id == saved.id
    refute unchanged.plan.id == selected.plan.id
    assert Agent.get(counter, & &1.calls) == ["workout_layout"]

    [token] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-action")
      |> LazyHTML.attribute("phx-value-client_session_id")

    {:error, {:live_redirect, %{to: "/session/" <> id}}} =
      view |> element("#home-action") |> render_click(%{"client_session_id" => token})

    session = Repo.get!(WorkoutSession, String.to_integer(id))
    assert session.plan_id == saved.id
    {:ok, runner, _} = live(conn, ~p"/session/#{session.id}")

    render_hook(runner, "save_session", %{
      "workout_session" => %{
        "burpee_count_actual" => 10,
        "duration_sec_actual" => 120,
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

    view |> element("#home-summary") |> render_click()
    view |> element("#home-new-workout") |> render_click()
    view |> element("#home-pill-pacing_style-unbroken") |> render_click()

    view
    |> form("#home-new-form",
      home_workout: %{
        reps: 140,
        duration: "20:00",
        pace: "5.0",
        note: "A minute's break at 11:00 and 40 seconds at 18:00"
      }
    )
    |> render_submit()

    render_async(view)
    assert Agent.get(counter, & &1.calls) == ["workout_request", "workout_layout"]
    assert has_element?(view, "#home-new-form[data-stage=review]")
    assert has_element?(view, "#home-new-review-inspection #home-inspection")
    assert has_element?(view, "#home-inspection .home-prescription-rest", "60s")
    assert has_element?(view, "#home-inspection .home-prescription-rest", "40s")
    assert has_element?(view, "#home-new-review-pauses", "Pauses: 60s at 11:00")
    assert has_element?(view, "#home-new-review-pauses", "40s at 18:00")
    assert has_element?(view, "#home_workout_note[disabled]", "40 seconds at 18:00")

    first_group =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-new-review-inspection .home-group-toggle")

    [group_id | _] = LazyHTML.attribute(first_group, "id")
    view |> element("##{group_id}") |> render_click()
    assert has_element?(view, "##{group_id}[aria-expanded=true]")
    assert has_element?(view, "#home-inspection .home-prescription-rest", "60s")

    view |> element("#home-request-save") |> render_click()
    render_async(view)

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

  test "the New form's note reaches the coach alongside the structured fields", %{view: view} do
    counter =
      fake_authoring_provider(%{
        "workout_request" => %{
          "burpee_type" => "six_count",
          "target_reps" => 10,
          "target_duration_sec" => 120,
          "pacing_style" => "even",
          "recovery" => "optional",
          "timed_rests" => [],
          "requested_pace_sec" => nil,
          "set_reps" => []
        },
        "workout_layout" => layout([[{10, 12.0, 12.0}]], "Noted new workout")
      })

    view |> element("#home-summary") |> render_click()
    view |> element("#home-new-workout") |> render_click()

    assert has_element?(
             view,
             "#home-new-form textarea[name='home_workout[note]'][maxlength='300']"
           )

    view |> element("#home-pill-pacing_style-even") |> render_click()

    view
    |> form("#home-new-form",
      home_workout: %{reps: 10, duration: "2:00", note: "slow and steady"}
    )
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#home-new-form[data-stage=review]")
    # The coach reads the note for sets and pauses, then plans with it.
    assert [extraction, layout] = Agent.get(counter, & &1.bodies)

    for body <- [extraction, layout] do
      assert body
             |> Jason.decode!()
             |> Map.fetch!("messages")
             |> Enum.any?(&(&1["content"] =~ "slow and steady"))
    end
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
