defmodule BurpeeTrainerWeb.Flows.PlannedNextWorkoutFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Workouts, Repo}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Policy, PlanNextWorkoutJob}
  alias BurpeeTrainer.Workouts.CoachRecommendation

  test "real SessionLive completion schedules next boundary while Home stays done_today", %{
    conn: conn
  } do
    user = user_fixture()
    scope = Scope.for_user(user)
    conn = init_test_session(conn, %{user_id: user.id})
    plan = plan_fixture(user)
    {:ok, started} = Workouts.start_plan(scope, plan.id, Ecto.UUID.generate())
    {:ok, session_view, _} = live(conn, ~p"/session/#{started.id}")

    render_hook(session_view, "save_session", %{
      "workout_session" => %{"burpee_count_actual" => 4, "duration_sec_actual" => 20},
      "tracking" => %{"enabled" => false, "trust" => "disabled", "cadence_ms" => []}
    })

    assert [%{args: args, scheduled_at: at}] = all_enqueued(worker: PlanNextWorkoutJob)
    assert DateTime.compare(at, DateTime.utc_now()) == :gt
    assert {:cancel, :slot_changed} = perform_job(PlanNextWorkoutJob, args)
    assert :ok = PlanNextWorkoutJob.enqueue(scope)
    assert length(all_enqueued(worker: PlanNextWorkoutJob)) == 1
    {:ok, home, _} = live(conn, ~p"/")
    assert has_element?(home, "#home-done-today")
    refute has_element?(home, "#home-action")
  end

  test "genuinely eligible job selects owned canonical workout and Home presents its rationale",
       %{conn: conn} do
    previous_provider = Application.get_env(:burpee_trainer, :llm_provider)
    previous_req = Req.default_options()

    on_exit(fn ->
      Application.put_env(:burpee_trainer, :llm_provider, previous_provider)
      Req.default_options(previous_req)
    end)

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://provider.test/v1",
      api_key: "k",
      model: "m"
    )

    user = user_fixture()
    scope = Scope.for_user(user)
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    plan = plan_fixture(user, %{target_reps: 30, target_duration_sec: slot.duration_sec})
    {:ok, before} = Workouts.ensure_home_selection(scope, slot)

    responses =
      start_supervised!(
        {Agent,
         fn ->
           [
             %{
               "choices" => [
                 %{
                   "message" => %{
                     "tool_calls" => [
                       %{
                         "id" => "select",
                         "function" => %{
                           "name" => "select_workout",
                           "arguments" =>
                             Jason.encode!(%{
                               "plan_id" => plan.id,
                               "rationale" => "Shorter sets after a tough week."
                             })
                         }
                       }
                     ]
                   }
                 }
               ]
             },
             %{
               "choices" => [
                 %{"message" => %{"content" => Jason.encode!(%{"reply" => "Ready."})}}
               ]
             }
           ]
         end}
      )

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, Agent.get_and_update(responses, fn [head | tail] -> {head, tail} end))
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    assert :ok =
             perform_job(PlanNextWorkoutJob, %{"user_id" => user.id, "slot_key" => slot.slot_key})

    assert {:ok, after_selection} = Workouts.ensure_home_selection(scope, slot)
    assert after_selection.plan.id == plan.id
    assert before.plan.origin == :built_in

    assert Repo.get!(CoachRecommendation, after_selection.recommendation_id).rationale ==
             "Shorter sets after a tough week."

    {:ok, home, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    assert has_element?(home, "#home-summary", plan.name)
    assert has_element?(home, "#home-planner-rationale", "Shorter sets after a tough week.")
    assert has_element?(home, "#home-action")
  end

  test "an eligible boundary does not replan an already owned selection", %{conn: conn} do
    user = user_fixture()
    scope = Scope.for_user(user)
    plan = plan_fixture(user)
    {:ok, slot} = Policy.required_slot(scope, DateTime.utc_now(:second))
    {:ok, fallback} = Workouts.ensure_home_selection(scope, slot)
    {:ok, _} = Workouts.select_home_workout(scope, fallback, plan.id)
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    generation = :sys.get_state(view.pid).socket.assigns.home_day_generation
    send(view.pid, {:home_day_boundary, generation})
    assert :sys.get_state(view.pid).socket.assigns.home_day_generation == generation + 1
    assert all_enqueued(worker: PlanNextWorkoutJob) == []
    assert has_element?(view, "#home-summary", plan.name)
  end
end
