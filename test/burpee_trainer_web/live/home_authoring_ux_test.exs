defmodule BurpeeTrainerWeb.HomeAuthoringUXTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  import BurpeeTrainerWeb.StudioHelpers
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

      # A New note is read against the entered fields; the note's words decide the sets.
      fixed =
        Enum.find_value(body["messages"], fn message ->
          case Jason.decode(message["content"]) do
            {:ok, %{"scope" => "fixed_fields", "request" => attrs}} -> attrs
            _ -> nil
          end
        end)

      note_sets =
        cond do
          Enum.any?(body["messages"], &String.contains?(&1["content"], "5x8, 5x7, 5x(7,6)")) ->
            List.duplicate(8, 5) ++
              List.duplicate(7, 5) ++ List.flatten(List.duplicate([7, 6], 5))

          Enum.any?(body["messages"], &String.contains?(&1["content"], "two sets of 30")) ->
            [30, 30]

          true ->
            []
        end

      constraints = if fixed, do: Map.put(fixed, "set_reps", note_sets), else: constraints

      constraints =
        constraints ||
          %{
            "burpee_type" => "six_count",
            "target_reps" =>
              if(
                Enum.any?(
                  body["messages"],
                  &String.contains?(&1["content"], "Increase to 150")
                ),
                do: 150,
                else: 120
              ),
            "target_duration_sec" => 1200,
            "pacing_style" => "unbroken",
            "recovery" => "required",
            "requested_pace_sec" => 5,
            "timed_rests" => []
          }

      constraints =
        if extracting? and is_nil(fixed),
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
         status: 200,
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

  test "a changed current selection cannot approve an outdated edit", %{
    view: view,
    user: user,
    selected: selected
  } do
    view |> element("#home-summary") |> render_click()
    view |> element("#home-edit-workout") |> render_click()

    view
    |> form("#home-edit-form",
      home_adjustment: %{
        instruction: "Change to 120 reps in 20 minutes, in two sets at 5 seconds active pace"
      }
    )
    |> render_submit()

    render_async(view)
    assert_receive {:provider_request, _}
    assert_receive {:provider_request, _}
    assert has_element?(view, "#home-request-confirm")
    other = plan_fixture(user, %{"state" => "published"})
    {:ok, changed} = Workouts.select_home_workout(Scope.for_user(user), selected, other.id)
    count = Repo.aggregate(WorkoutPlan, :count)
    view |> element("#home-request-confirm") |> render_click()
    render_async(view)
    refute has_element?(view, "#home-new-saved")
    assert has_element?(view, "#home-adjustment-error", "changed")
    assert Repo.aggregate(WorkoutPlan, :count) == count

    assert {:ok, ^changed} =
             Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))

    refute_received {:provider_request, _}
  end

  test "a saved workout stays selectable after dismissing the saved notice", %{
    view: view,
    user: user,
    selected: selected
  } do
    walk(view, reps: 10, minutes: 5, pace_ups: 1)
    view |> form("#home-edit-form", home_adjustment: %{instruction: ""}) |> render_submit()
    render_async(view, 2_000)
    assert_receive {:provider_request, _}
    view |> element("#home-request-save") |> render_click()
    render_async(view, 2_000)
    assert has_element?(view, "#home-new-saved")
    view |> element("#home-new-dismiss") |> render_click()
    refute has_element?(view, "#home-new-saved")

    [saved] =
      Enum.filter(
        Workouts.list_library(Scope.for_user(user)),
        &(&1.name == "Independent new workout")
      )

    assert {:ok, unchanged} =
             Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))

    assert unchanged.plan.id == selected.plan.id

    render_click(view, "open_chooser", %{})
    assert has_element?(view, "#home-alternative-plan-#{saved.id}")
    assert has_element?(view, "#home-delete-workout-#{saved.id}")
    view |> element("#home-alternative-plan-#{saved.id}-select") |> render_click()
    view |> element("#home-swap-confirm") |> render_click()
    assert has_element?(view, "#home-summary", "Independent new workout")
    refute_received {:provider_request, _}
  end

  test "a New workout is refined by talking once it is proposed", %{view: view} do
    walk(view, reps: 10, minutes: 5, pace_ups: 1)
    view |> form("#home-edit-form", home_adjustment: %{instruction: ""}) |> render_submit()
    render_async(view, 2_000)
    assert has_element?(view, "#home-edit-review #home-request-confirm")
    assert has_element?(view, "#studio-proposal .home-prescription-reps")

    view
    |> form("#home-edit-form", home_adjustment: %{instruction: "Increase to 150 reps"})
    |> render_submit()

    render_async(view, 2_000)

    # What the questions made stays above, as one message; the new proposal follows the ask.
    assert has_element?(view, "#studio-thread .studio-bubble", "10 reps")
    assert has_element?(view, "#studio-proposal .studio-chip", "150 reps")
    assert has_element?(view, ".studio-turn", "10 reps")
    assert has_element?(view, "#home-design-ask", "Increase to 150")
    assert has_element?(view, "#studio-proposal", "150 reps")

    view |> element("#home-request-save") |> render_click()
    render_async(view, 2_000)
    assert has_element?(view, "#home-new-saved")
  end

  test "provider failure retains the answers and the current pin without offering approval", %{
    view: view,
    user: user,
    selected: selected
  } do
    Application.put_env(:burpee_trainer, :llm_provider, enabled: false)
    count = Repo.aggregate(WorkoutPlan, :count)
    walk(view, reps: 140, pace_ups: 1)
    view |> form("#home-edit-form", home_adjustment: %{instruction: ""}) |> render_submit()
    render_async(view, 2_000)
    assert has_element?(view, "#studio-request", "140 reps")
    refute has_element?(view, "#home-request-confirm")
    assert has_element?(view, "#home-adjustment-error", "Coach unavailable")
    assert Repo.aggregate(WorkoutPlan, :count) == count

    assert {:ok, unchanged} =
             Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))

    assert unchanged.plan.id == selected.plan.id
  end

  test "going back to an answer drops the proposal made from it", %{
    view: view,
    user: user,
    selected: selected
  } do
    walk(view, reps: 10, minutes: 5, pace_ups: 1)
    view |> form("#home-edit-form", home_adjustment: %{instruction: ""}) |> render_submit()
    render_async(view, 2_000)
    assert has_element?(view, "#home-request-confirm")

    # Back is one step back: to the message, without the proposal made from it.
    view |> element("#studio-back") |> render_click()
    refute has_element?(view, "#home-request-confirm, #studio-proposal")
    assert has_element?(view, "#studio-request")
    assert has_element?(view, "#home-edit-instruction", "Additional request:")

    view |> element("#studio-part-reps") |> render_click()
    assert has_element?(view, "#studio-step", "How many reps?")
    assert has_element?(view, "#studio-reps-value", "10")

    view |> element("#home-request-abort") |> render_click()
    assert has_element?(view, "#home-inspection")
    assert {:ok, unchanged} = Workouts.verify_home_selection(Scope.for_user(user), selected)
    assert unchanged.id == selected.plan.id
    assert Workouts.current_started_session(Scope.for_user(user)) == nil
  end

  test "a note whose sets do not add up to the reps is explained before any plan", %{view: view} do
    count = Repo.aggregate(WorkoutPlan, :count)
    walk(view, reps: 140, pace_ups: 1)

    view
    |> form("#home-edit-form", home_adjustment: %{instruction: "two sets of 30"})
    |> render_submit()

    render_async(view, 2_000)
    assert_receive {:provider_request, %{"messages" => _}}
    assert has_element?(view, "#home-adjustment-error", "doesn't add up")
    refute has_element?(view, "#home-request-confirm")
    assert Repo.aggregate(WorkoutPlan, :count) == count
  end

  test "a returned pattern mismatch is explained before any save", %{view: view} do
    count = Repo.aggregate(WorkoutPlan, :count)
    walk(view, reps: 140, pace_ups: 1)

    view
    |> form("#home-edit-form", home_adjustment: %{instruction: "5x8, 5x7, 5x(7,6)"})
    |> render_submit()

    render_async(view, 2_000)
    # Reading the note, the layout and its one correction.
    for _call <- 1..3, do: assert_receive({:provider_request, _})
    assert has_element?(view, "#home-adjustment-error", "ordered set pattern")
    assert has_element?(view, "#home-adjustment-error", "Returned 2 sets; expected 20")
    refute has_element?(view, "#home-request-confirm")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    refute_received {:provider_request, _}
  end

  test "going back during preparation cancels the task and a late result cannot save", %{
    view: view
  } do
    parent = self()

    ReqStub.default(fn request ->
      send(parent, {:planning_started, self()})

      receive do
        :release -> {request, %Req.Response{status: 500}}
      end
    end)

    count = Repo.aggregate(WorkoutPlan, :count)
    walk(view, reps: 140, pace_ups: 1)
    view |> form("#home-edit-form", home_adjustment: %{instruction: ""}) |> render_submit()
    assert_receive {:planning_started, task}
    monitor = Process.monitor(task)
    view |> element("#studio-back") |> render_click()
    assert_receive {:DOWN, ^monitor, :process, ^task, _}
    send(task, :release)
    render_async(view, 2_000)
    assert has_element?(view, "#studio-pace-value", "5.0")
    refute has_element?(view, "#home-request-confirm")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    view |> element("#home-request-abort") |> render_click()
    assert has_element?(view, "#home-inspection")
  end

  defp selected_slot(user) do
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    slot
  end
end
