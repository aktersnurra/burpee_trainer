defmodule BurpeeTrainerWeb.HomeAuthoringUXTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Accounts, Workouts, Repo}
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

    Req.default_options(
      adapter: fn request ->
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
              "rest_weights" => [1]
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
      end
    )

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
    open_new(view)
    view |> element("#home-pill-pacing_style-even") |> render_click()
    view |> form("#home-new-form", home_workout: %{reps: 10, duration: "2:00"}) |> render_submit()
    render_async(view)
    assert_receive {:provider_request, _}
    view |> element("#home-request-confirm") |> render_click()
    render_async(view)
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
    assert has_element?(view, "#home-summary", "Independent new workout")
    refute_received {:provider_request, _}
  end

  test "provider failure retains input and current pin without offering approval", %{
    view: view,
    user: user,
    selected: selected
  } do
    Application.put_env(:burpee_trainer, :llm_provider, enabled: false)
    open_new(view)
    count = Repo.aggregate(WorkoutPlan, :count)
    view |> form("#home-new-form", home_workout: %{reps: 140}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#home-new-reps[value='140']")
    refute has_element?(view, "#home-request-confirm")
    assert has_element?(view, "#home-adjustment-error", "Coach unavailable")
    assert Repo.aggregate(WorkoutPlan, :count) == count

    assert {:ok, unchanged} =
             Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))

    assert unchanged.plan.id == selected.plan.id
  end

  test "all three states use the same fields, pills and local budget; pencil invalidates approval",
       %{view: view, user: user, selected: selected} do
    open_new(view)
    ids = field_ids(view)

    view
    |> form("#home-new-form", home_workout: %{reps: 140, pace: "5", sets: "", duration: "20:00"})
    |> render_change()

    assert has_element?(view, "#home-workout-budget", "11:40")
    assert has_element?(view, "#home-workout-budget", "8:20")
    refute_received {:provider_request, _}
    view |> element("#home-pill-pacing_style-even") |> render_click()
    assert has_element?(view, "#home-pill-pacing_style-even[aria-pressed=true]")
    refute_received {:provider_request, _}
    view |> form("#home-new-form") |> render_submit()
    render_async(view)
    assert_receive {:provider_request, _}
    assert field_ids(view) == ids
    assert has_element?(view, "#home-request-edit[aria-label='Edit workout']")
    view |> element("#home-request-edit") |> render_click()
    assert field_ids(view) == ids
    refute has_element?(view, "#home-request-confirm")
    view |> form("#home-new-form", home_workout: %{reps: 130, sets: ""}) |> render_change()
    assert has_element?(view, "#home-workout-budget", "10:50")
    refute_received {:provider_request, _}
    view |> element("#home-request-abort") |> render_click()
    assert has_element?(view, "#home-inspection")
    assert {:ok, unchanged} = Workouts.verify_home_selection(Scope.for_user(user), selected)
    assert unchanged.id == selected.plan.id
    assert Workouts.current_started_session(Scope.for_user(user)) == nil
  end

  test "malformed rests and contradictory patterns are local errors", %{view: view} do
    open_new(view)
    view |> form("#home-new-form", home_workout: %{rests: "not a rest"}) |> render_submit()
    assert has_element?(view, "#home-new-form")
    assert has_element?(view, "#home-new-form", "Use 60s at 11:00")
    refute_received {:provider_request, _}
    view |> form("#home-new-form", home_workout: %{rests: "", sets: "5x8"}) |> render_submit()
    assert has_element?(view, "#home-new-form", "Pattern contains 40 reps")
    refute_received {:provider_request, _}
  end

  test "a returned pattern mismatch is explained before any save", %{view: view} do
    open_new(view)
    count = Repo.aggregate(WorkoutPlan, :count)

    view
    |> form("#home-new-form", home_workout: %{reps: 140, pace: 5, sets: "5x8,5x7,5x(7,6)"})
    |> render_submit()

    render_async(view)
    assert_receive {:provider_request, _}
    assert_receive {:provider_request, _}
    assert has_element?(view, "#home-adjustment-error", "ordered set pattern")
    assert has_element?(view, "#home-new-form", "Returned 2 sets; expected 20")
    refute has_element?(view, "#home-request-confirm")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    refute_received {:provider_request, _}
  end

  test "editing during preparation cancels the task and a late result cannot save", %{view: view} do
    parent = self()

    Req.default_options(
      adapter: fn request ->
        send(parent, {:planning_started, self()})

        receive do
          :release -> {request, %Req.Response{status: 500}}
        end
      end
    )

    open_new(view)
    count = Repo.aggregate(WorkoutPlan, :count)
    view |> form("#home-new-form", home_workout: %{reps: 140}) |> render_submit()
    assert_receive {:planning_started, task}
    monitor = Process.monitor(task)
    view |> form("#home-new-form", home_workout: %{reps: 130}) |> render_change()
    assert_receive {:DOWN, ^monitor, :process, ^task, _}
    send(task, :release)
    render_async(view)
    assert has_element?(view, "#home-new-reps[value='130']")
    refute has_element?(view, "#home-request-confirm")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    view |> element("#home-request-abort") |> render_click()
    assert has_element?(view, "#home-inspection")
  end

  defp open_new(view) do
    view |> element("#home-summary") |> render_click()
    view |> element("#home-new-workout") |> render_click()
  end

  defp field_ids(view) do
    render(view)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(
      "#home-new-form input:not([type=hidden]), #home-new-form textarea, #home-workout-budget"
    )
    |> LazyHTML.attribute("id")
  end

  defp selected_slot(user) do
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    slot
  end
end
