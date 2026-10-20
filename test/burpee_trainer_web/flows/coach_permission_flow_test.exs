defmodule BurpeeTrainerWeb.CoachPermissionFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.{Accounts, Mcp, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Client, MemoryJob, PlanNextWorkoutJob, Summary, SummaryJob}
  alias BurpeeTrainer.Insights.NarrateJob

  defp coached_over_mcp(user) do
    {:ok, user} = Accounts.put_coach(user, :mcp)
    user
  end

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    %{conn: conn, user: user}
  end

  test "the app never calls the model for a user coached over MCP", %{user: user} do
    previous = Application.get_env(:burpee_trainer, :llm_provider)
    on_exit(fn -> Application.put_env(:burpee_trainer, :llm_provider, previous) end)

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://provider.test/v1",
      api_key: "k",
      model: "m"
    )

    scope = Scope.for_user(coached_over_mcp(user))

    ledger = %{scope: scope, purpose: "summary", run_id: Ecto.UUID.generate()}
    assert {:error, %{code: :mcp_coach}} = Client.chat([], ledger: ledger)
    assert llm_call_count(scope) == 0
  end

  test "a session done or logged by a user coached over MCP queues none of the app's coach",
       %{user: user} do
    scope = Scope.for_user(coached_over_mcp(user))
    plan = plan_fixture(user)
    {:ok, started} = Workouts.start_plan(scope, plan.id, Ecto.UUID.generate())

    attrs = %{"burpee_count_actual" => 10, "duration_sec_actual" => 60, "note_post" => "Sore"}
    assert {:ok, _} = Workouts.complete_session(scope, started.id, attrs, :timed)

    assert {:ok, _} =
             Workouts.log_session(
               scope,
               %{
                 "burpee_type" => "six_count",
                 "burpee_count_actual" => 20,
                 "duration_sec_actual" => 120
               },
               DateTime.utc_now(:second)
             )

    for worker <- [PlanNextWorkoutJob, SummaryJob, MemoryJob, NarrateJob],
        do: assert(all_enqueued(worker: worker) == [], "queued #{inspect(worker)}")
  end

  test "Home for a user coached over MCP shows the note left over MCP and points there, with no message box",
       %{conn: conn, user: user} do
    user = coached_over_mcp(user)
    scope = Scope.for_user(user)
    free_form_session_fixture(user, %{duration_sec_actual: 1_200})

    {:reply, %{"result" => %{"isError" => false}}} =
      Mcp.handle(scope, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "set_coach_note",
          "arguments" => %{
            "text" => "Two sessions left; keep Thursday easy.",
            "review" => "Six-count held steady this week."
          }
        }
      })

    assert Summary.get(scope).source == :mcp

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    assert has_element?(view, "#home-coach-note", "Two sessions left; keep Thursday easy.")
    assert has_element?(view, "#home-coach-week")
    assert has_element?(view, "#home-coach-mcp", "MCP connection")
    refute has_element?(view, "#home-coach-message-form")
    refute has_element?(view, ".coach-quick-replies")
  end

  test "Home for a user coached over MCP points there even before anything was written",
       %{conn: conn, user: user} do
    user = coached_over_mcp(user)
    free_form_session_fixture(user, %{duration_sec_actual: 1_200})

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    assert has_element?(view, "#home-coach-panel #home-coach-mcp")
    assert all_enqueued(worker: SummaryJob) == []
  end

  test "a user coached over MCP can start and switch the workout, but not ask the app to design one",
       %{conn: conn, user: user} do
    user = coached_over_mcp(user)

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    assert has_element?(view, "#home-action[data-primary-action=start]")
    assert has_element?(view, "#home-title-action")
    assert has_element?(view, "#home-workout-mcp", "MCP connection")
    refute has_element?(view, "#home-edit-workout")
    refute has_element?(view, "#home-new-workout")

    # A stale page's events ask nothing of the app's coach.
    render_click(view, "toggle_summary", %{})
    render_click(view, "new_workout", %{})
    refute has_element?(view, "#home-new-reps")
    render_click(view, "edit_current_workout", %{})
    refute has_element?(view, "#home-edit-form")
  end

  test "a user coached over MCP cannot message the app's coach from a stale page",
       %{conn: conn, user: user} do
    user = coached_over_mcp(user)
    free_form_session_fixture(user, %{duration_sec_actual: 1_200})

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    render_click(view, "coach_message", %{"coach_message" => %{"text" => "Harder please"}})
    refute has_element?(view, "#home-coach-pending")
    assert llm_call_count(Scope.for_user(user)) == 0
  end

  test "a summary queued before the coach changed to MCP keeps the note written over MCP",
       %{user: user} do
    free_form_session_fixture(user, %{duration_sec_actual: 1_200})
    {:ok, _job} = SummaryJob.admit(Scope.for_user(user))
    scope = Scope.for_user(coached_over_mcp(user))

    {:reply, %{"result" => %{"isError" => false}}} =
      Mcp.handle(scope, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "set_coach_note",
          "arguments" => %{"text" => "Keep Thursday easy."}
        }
      })

    assert {:cancel, :mcp_coach} = perform_job(SummaryJob, %{user_id: user.id})
    assert %{source: :mcp, text: "Keep Thursday easy."} = Summary.get(scope)
  end

  test "with the coach, Home still has the conversation", %{conn: conn, user: user} do
    free_form_session_fixture(user, %{duration_sec_actual: 1_200})
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    assert has_element?(view, "#home-coach-message-form")
  end

  test "set_coach_note refuses what the athlete should not read", %{user: user} do
    scope = Scope.for_user(user)

    for arguments <- [
          %{"text" => ""},
          %{"text" => String.duplicate("long ", 100)},
          %{"text" => "Your level_1b is near."},
          %{"text" => "Fine.", "extra" => 1}
        ] do
      {:reply, %{"result" => result}} =
        Mcp.handle(scope, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "set_coach_note", "arguments" => arguments}
        })

      assert result["isError"], "kept #{inspect(arguments)}"
    end

    assert Summary.get(scope) == nil
  end
end
