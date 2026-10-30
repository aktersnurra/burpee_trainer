defmodule BurpeeTrainerWeb.Flows.EditWorkoutFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest
  import BurpeeTrainerWeb.StudioHelpers
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Accounts, ReqStub, Workouts, Repo}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.WorkoutPlan

  setup %{conn: conn} = context do
    parent = self()
    hold_plan? = context[:hold_edit_plan] || false
    previous_req = Req.default_options()
    previous_provider = Application.get_env(:burpee_trainer, :llm_provider)

    on_exit(fn ->
      Req.default_options(previous_req)
      Application.put_env(:burpee_trainer, :llm_provider, previous_provider)
    end)

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://provider.test/v1",
      api_key: "test",
      model: "test"
    )

    ReqStub.default(fn request ->
      body = Jason.decode!(request.body)
      send(parent, {:provider_request, body})

      constraints =
        Enum.find_value(body["messages"], fn message ->
          case Jason.decode(message["content"]) do
            {:ok, %{"scope" => "confirmed_workout_request", "request" => attrs}} -> attrs
            _ -> nil
          end
        end)

      if constraints && hold_plan? do
        send(parent, {:edit_planning_waiting, self()})

        receive do
          :release_plan -> :ok
        end
      end

      extracting? = is_nil(constraints)
      provider_down? = extracting? and requested_reps(body["messages"]) == 999

      constraints =
        constraints ||
          %{
            "burpee_type" => "six_count",
            "target_reps" => requested_reps(body["messages"]),
            "target_duration_sec" => 1200,
            "pacing_style" => "unbroken",
            "recovery" => "required",
            "requested_pace_sec" => 5,
            "timed_rests" => []
          }

      constraints =
        if extracting?,
          do:
            Map.put(
              constraints,
              "set_reps",
              List.duplicate(div(constraints["target_reps"], 2), 2)
            ),
          else: constraints

      reps = constraints["target_reps"]

      work = fn reps ->
        %{"kind" => "work", "reps" => reps, "sec_per_rep" => 5, "sec_per_burpee" => 5}
      end

      layout = %{
        "name" => "Independent new workout",
        "rationale" => "Continuous sets and local recovery.",
        "phases" => [
          %{
            "sets" => [
              Map.delete(work.(div(reps, 2)), "kind"),
              Map.delete(work.(reps - div(reps, 2)), "kind")
            ],
            "rests" => [%{"share" => 1}]
          }
        ]
      }

      {request,
       %Req.Response{
         status: if(provider_down?, do: 503, else: 200),
         body:
           Jason.encode!(%{
             "choices" => [
               %{
                 "message" => %{
                   "content" => Jason.encode!(if(extracting?, do: constraints, else: layout))
                 }
               }
             ]
           })
       }}
    end)

    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    {:ok, selected} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    %{view: view, user: user, selected: selected}
  end

  test "swiping up offers Edit and New; Edit opens a chat that begins with today's workout",
       %{view: view, selected: selected} do
    # Closed, the workout offers only the swap swipe; edit and new wait until it is opened.
    refute has_element?(view, "#home-grab")
    view |> element("#home-summary") |> render_click()

    # The swipe up is invisible, so the opened workout has a handle for it; both lead to the same sheet.
    assert has_element?(view, "#home-grab[aria-label='Edit, swap or new workout']")
    view |> element("#home-grab") |> render_click()
    assert has_element?(view, "#home-options-sheet")
    refute has_element?(view, "#home-grab")
    render_hook(view, "close_options", %{})
    # The swipe is the hook's event, the same one the buttons lead to.
    render_hook(view, "open_options", %{})
    assert has_element?(view, "#home-options-sheet #home-options-edit", "Edit this workout")
    assert has_element?(view, "#home-options-sheet #home-options-new", "New workout")
    assert has_element?(view, "#home-options-sheet #home-options-swap", "Swap workout")

    # Swap opens the list and takes the sheet away; nothing needed the workout opened first.
    view |> element("#home-options-swap") |> render_click()
    refute has_element?(view, "#home-options-sheet")
    assert has_element?(view, "#home-alternatives-panel:not([hidden])")
    render_click(view, "close_chooser", %{})
    render_hook(view, "open_options", %{})

    render_hook(view, "close_options", %{})
    refute has_element?(view, "#home-options-sheet")
    render_hook(view, "open_options", %{})
    view |> element("#home-options-edit") |> render_click()
    refute has_element?(view, "#home-options-sheet")

    # The studio takes Home's place: the coach's first message is today's workout.
    assert has_element?(view, "#home-studio h1#home-authoring-heading", "Edit workout")
    assert has_element?(view, "#studio-thread #studio-source", selected.plan.name)
    assert has_element?(view, "#studio-source #home-inspection table")
    assert has_element?(view, "#studio-thread", "What would you like to change?")
    refute has_element?(view, "#home-workout-hero, .home-workout-actions, #home-grab")

    # The box is docked, named by its placeholder; the label is for screen readers.
    assert has_element?(view, "#home-chat-dock #home-edit-form")

    assert has_element?(
             view,
             "label[for=home-edit-instruction] .label",
             "What do you want to change?"
           )

    assert has_element?(view, "#home-edit-instruction[placeholder='What should change?']")
    assert has_element?(view, "#home-edit-form #home-edit-send[aria-label=Send]")
    refute has_element?(view, "#home-chat-actions")

    # Back leaves without a change.
    assert has_element?(view, "#home-request-abort[aria-label='Cancel edit'] .hero-chevron-left")
    view |> element("#home-request-abort") |> render_click()
    refute has_element?(view, "#home-studio")
    assert has_element?(view, ".home-workout-actions #home-action")
  end

  @tag hold_edit_plan: true
  test "Edit reviews and saves a new variation while the original and a used session stay unchanged",
       %{conn: conn, user: user} do
    definition = %{
      "version" => 1,
      "name" => "140 rep favourite",
      "burpee_type" => "six_count",
      "target_reps" => 140,
      "target_duration_sec" => 1200,
      "pacing_style" => "unbroken",
      "rationale" => "Two continuous sets with recovery.",
      "events" => [
        %{"kind" => "work", "reps" => 70, "sec_per_rep" => 5, "sec_per_burpee" => 5},
        %{"kind" => "rest", "duration_sec" => 500},
        %{"kind" => "work", "reps" => 70, "sec_per_rep" => 5, "sec_per_burpee" => 5}
      ]
    }

    original = plan_fixture(user, %{"definition" => definition, "state" => "published"})
    used_at = DateTime.add(DateTime.utc_now(:second), -86400, :second)
    # Seed history directly: completed session timestamps cannot be backdated after first use.
    used =
      Repo.insert!(%BurpeeTrainer.Workouts.WorkoutSession{
        user_id: user.id,
        plan_id: original.id,
        state: :completed,
        source_kind: :plan,
        client_session_id: Ecto.UUID.generate(),
        display_name_snapshot: original.name,
        workout_type_snapshot: original.burpee_type,
        burpee_type: original.burpee_type,
        program_snapshot: original.program_json,
        content_hash: original.content_hash,
        burpee_count_planned: 140,
        duration_sec_planned: 1200,
        burpee_count_actual: 140,
        duration_sec_actual: 1200,
        capture_mode: :timed,
        started_at: DateTime.add(used_at, -1200, :second),
        completed_at: used_at
      })

    {:ok, selected} = Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))
    {:ok, pin} = Workouts.select_home_workout(Scope.for_user(user), selected, original.id)
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    view |> element("#home-summary") |> render_click()
    open_edit(view)
    refute has_element?(view, "#studio-reps-value, #studio-duration-value")

    view
    |> form("#home-edit-form", home_adjustment: %{instruction: "Increase to 160 reps"})
    |> render_change()

    view |> element("#home-request-abort") |> render_click()
    assert {:ok, ^pin} = Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))

    assert Repo.aggregate(
             from(plan in WorkoutPlan, where: plan.user_id == ^user.id and plan.state == :draft),
             :count
           ) == 0

    refute_received {:provider_request, _}
    open_edit(view)
    assert has_element?(view, "#home-edit-instruction")
    instruction = "Increase to 150 reps, keep 20 minutes, 5 seconds active pace and two sets."

    view
    |> form("#home-edit-form", home_adjustment: %{instruction: instruction})
    |> render_change()

    render_patch(view, "/progress")
    render_patch(view, "/")
    assert has_element?(view, "#home-edit-instruction", instruction)
    refute_received {:provider_request, _}
    count = Repo.aggregate(WorkoutPlan, :count)
    view |> form("#home-edit-form") |> render_submit()
    assert_receive {:edit_planning_waiting, planner}, 1_000
    assert has_element?(view, "#home-update-loading[role=status] .studio-spinner")
    assert has_element?(view, "#home-request-abort:not([disabled])")
    # The message stays on screen with the loader, and the box waits for the answer.
    assert has_element?(view, "#home-design-ask", instruction)
    assert has_element?(view, "#home-edit-instruction[disabled]")
    refute has_element?(view, "#home-edit-review")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    send(planner, :release_plan)
    render_async(view)
    assert_receive {:provider_request, _interpretation}
    assert_receive {:provider_request, body}

    source =
      Enum.find_value(body["messages"], fn message ->
        case Jason.decode(message["content"]) do
          {:ok, %{"scope" => "edit_workout_source"} = source} -> source
          _ -> nil
        end
      end)

    assert source["definition"]["target_reps"] == 140
    # The proposal arrives as a card below the ask, with what changed marked in its table.
    assert has_element?(view, "#studio-thread #home-design-ask", instruction)
    assert has_element?(view, "#studio-proposal .studio-card-totals", "150 reps")
    assert has_element?(view, "#studio-source:not(:has(table))")
    assert has_element?(view, "#home-edit-review #home-inspection table")
    assert has_element?(view, "#home-edit-review td.home-changed.home-prescription-reps", "75")

    # Edit refines by talking, so there is no way back to a form; Run and Save sit under the card.
    refute has_element?(view, "#home-request-edit")

    assert has_element?(
             view,
             "#home-edit-review #home-request-run.studio-pill-primary",
             "Run"
           )

    assert has_element?(view, "#home-edit-review #home-request-save", "Save")
    refute has_element?(view, "#home-chat-dock #home-request-run")

    assert has_element?(view, "#home-edit-review .home-prescription-reps", "75")
    assert has_element?(view, "#home-edit-review .home-prescription-every", "5s")
    assert has_element?(view, "#home-edit-review .home-prescription-rest", "7:30")
    refute has_element?(view, "#home-update-loading")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    view |> element("#home-request-run") |> render_click()
    # Run starts it: the session is its own, on the new workout.
    {"/session/" <> started, _flash} = assert_redirect(view, 2_000)

    assert Repo.aggregate(
             from(plan in WorkoutPlan, where: plan.user_id == ^user.id and plan.state == :draft),
             :count
           ) == 0

    [saved] =
      Enum.filter(
        Workouts.list_library(Scope.for_user(user)),
        &(&1.user_id == user.id and &1.target_reps == 150)
      )

    assert saved.state == :published
    assert saved.id != original.id
    assert saved.definition_json["target_reps"] == 150
    assert Repo.aggregate(WorkoutPlan, :count) == count + 1
    refute_received {:provider_request, _}

    assert {:ok, chosen} =
             Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))

    assert chosen.plan.id == saved.id
    assert Repo.get!(WorkoutPlan, original.id).definition_json == original.definition_json

    assert Repo.get!(BurpeeTrainer.Workouts.WorkoutSession, used.id).program_snapshot ==
             used.program_snapshot

    {:ok, reopened, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    # The workout is under way, so Home offers to resume it.
    assert has_element?(reopened, "#resume-recommended-workout")
    assert Enum.any?(Workouts.list_library(Scope.for_user(user)), &(&1.id == original.id))

    assert {:ok, %{plan: %{id: saved_id}}} =
             Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))

    assert saved_id == saved.id

    assert Repo.get!(BurpeeTrainer.Workouts.WorkoutSession, String.to_integer(started)).plan_id ==
             saved.id
  end

  @tag hold_edit_plan: true
  test "each follow-up refines the proposal on screen, not the workout the design started from",
       %{view: view, selected: selected} do
    view |> element("#home-summary") |> render_click()
    open_edit(view)

    view
    |> form("#home-edit-form", home_adjustment: %{instruction: "Increase to 150 reps"})
    |> render_submit()

    assert_receive {:edit_planning_waiting, planner}, 1_000
    send(planner, :release_plan)
    render_async(view)
    assert has_element?(view, "#studio-thread #home-design-ask", "Increase to 150 reps")
    assert has_element?(view, "#studio-proposal .studio-card-totals", "150 reps")
    # The box stays, empty, for the next message.
    assert has_element?(view, "#home-chat-dock #home-edit-form #home-edit-instruction")
    flush_provider_requests()

    view
    |> form("#home-edit-form", home_adjustment: %{instruction: "Increase to 160 reps"})
    |> render_submit()

    # The proposal stays in view while the coach works on the next one.
    assert_receive {:edit_planning_waiting, planner}, 1_000
    assert has_element?(view, "#studio-thread #home-design-pending", "Increase to 160 reps")
    assert has_element?(view, "#studio-proposal #home-inspection table")
    assert has_element?(view, "#home-edit-instruction[disabled]")
    send(planner, :release_plan)
    render_async(view)

    requests = provider_requests()

    interpretation =
      Enum.find_value(requests, fn body ->
        Enum.find_value(body["messages"], fn message ->
          case Jason.decode(message["content"]) do
            {:ok, %{"scope" => "workout_design"} = design} -> design
            _ -> nil
          end
        end)
      end)

    # Read against the 150-rep proposal, not the workout the design started from.
    assert interpretation["current_definition"]["target_reps"] == 150
    assert interpretation["current_definition"]["target_reps"] != selected.plan.target_reps

    scopes =
      for body <- requests, message <- body["messages"], reduce: [] do
        scopes ->
          case Jason.decode(message["content"]) do
            {:ok, %{"scope" => scope} = decoded} -> [{scope, decoded} | scopes]
            _ -> scopes
          end
      end

    assert {_, %{"definition" => %{"target_reps" => 150}}} =
             List.keyfind(scopes, "current_proposal", 0)

    assert List.keyfind(scopes, "edit_workout_source", 0) == nil

    # The first ask and what it became are kept; the newest ask heads the proposal.
    assert has_element?(view, "#studio-thread .studio-bubble", "Increase to 150 reps")
    assert has_element?(view, "#studio-thread .studio-turn", "150 reps")
    assert has_element?(view, "#studio-thread #home-design-ask", "Increase to 160 reps")
    refute has_element?(view, "#home-design-pending")
    assert has_element?(view, "#studio-proposal .studio-card-totals", "160 reps")
    refute has_element?(view, "#home-edit-instruction", "Increase")

    view |> element("#home-request-save") |> render_click()
    render_async(view)

    assert [saved] =
             Enum.filter(
               Workouts.list_library(Scope.for_user(Repo.one!(Accounts.User))),
               &(&1.target_reps == 160)
             )

    assert saved.id != selected.plan.id
  end

  test "a follow-up the coach cannot make leaves the proposal on screen to try again",
       %{view: view} do
    view |> element("#home-summary") |> render_click()
    open_edit(view)

    view
    |> form("#home-edit-form", home_adjustment: %{instruction: "Increase to 150 reps"})
    |> render_submit()

    render_async(view)

    view
    |> form("#home-edit-form", home_adjustment: %{instruction: "Increase to 999 reps"})
    |> render_submit()

    render_async(view)

    assert has_element?(view, "#home-adjustment-error", "your proposal is unchanged")
    assert has_element?(view, "#studio-proposal .studio-card-totals", "150 reps")
    assert has_element?(view, "#home-edit-review #home-inspection table")
    refute has_element?(view, "#home-design-pending")
    # What was typed is still there to send again.
    assert has_element?(view, "#home-edit-instruction:not([disabled])", "Increase to 999 reps")
    assert has_element?(view, "#home-request-run:not([disabled])")
  end

  test "a set's numbers change by hand with no call; the rests keep the length, Run takes it",
       %{view: view} do
    view |> element("#home-summary") |> render_click()
    open_edit(view)

    view
    |> form("#home-edit-form", home_adjustment: %{instruction: "Increase to 150 reps"})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#studio-proposal .studio-card-totals", "150 reps")
    flush_provider_requests()

    # A tap on the first set's row selects it; its reps step down by one.
    view |> element("#studio-proposal tr.home-editable-row[phx-value-index='0']") |> render_click()
    assert has_element?(view, "#studio-hand-edit", "Set 1")
    assert has_element?(view, "#studio-hand-reps", "75")
    view |> element("#studio-hand-reps-down") |> render_click()

    assert has_element?(view, "#studio-hand-reps", "74")
    assert has_element?(view, "#studio-proposal .studio-card-totals", "149 reps")
    assert has_element?(view, "#studio-proposal .studio-card-totals", "20 min")
    # What changed from the proposal before reads marked.
    assert has_element?(view, "#studio-proposal .studio-chip-changed", "149 reps")
    assert has_element?(view, "#studio-proposal td.home-changed", "74")
    refute_received {:provider_request, _}

    view |> element("#home-request-save") |> render_click()
    render_async(view)

    assert [saved] =
             Enum.filter(
               Workouts.list_library(Scope.for_user(Repo.one!(Accounts.User))),
               &(&1.target_reps == 149)
             )

    assert saved.target_duration_sec == 1_200
  end

  defp provider_requests(acc \\ []) do
    receive do
      {:provider_request, body} -> provider_requests([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp flush_provider_requests, do: provider_requests()

  # The reps the active instruction asks for ("Increase to 160 reps"); 120 otherwise.
  defp requested_reps(messages) do
    Enum.find_value(messages, 120, fn message ->
      with {:ok, %{"scope" => "workout_design", "active_attempt" => %{"instruction" => text}}} <-
             Jason.decode(message["content"]),
           [_, reps] <- Regex.run(~r/Increase to (\d+)/, text) do
        String.to_integer(reps)
      else
        _ -> nil
      end
    end)
  end

  defp selected_slot(user) do
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    slot
  end
end
