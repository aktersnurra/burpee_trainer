defmodule BurpeeTrainerWeb.CoachPermissionFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  use Oban.Testing, repo: BurpeeTrainer.Repo, engine: Oban.Engines.Lite

  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest

  alias BurpeeTrainer.{Accounts, Mcp, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Client, MemoryJob, PlanNextWorkoutJob, Summary, SummaryJob}
  alias BurpeeTrainer.Insights.NarrateJob

  defp coached_by_claude(user) do
    {:ok, user} = Accounts.put_coach(user, :claude)
    user
  end

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.update_timezone(user, "Etc/UTC")
    %{conn: conn, user: user}
  end

  test "the app never calls the model for a user Claude coaches", %{user: user} do
    previous = Application.get_env(:burpee_trainer, :llm_provider)
    on_exit(fn -> Application.put_env(:burpee_trainer, :llm_provider, previous) end)

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://provider.test/v1",
      api_key: "k",
      model: "m"
    )

    scope = Scope.for_user(coached_by_claude(user))

    ledger = %{scope: scope, purpose: "summary", run_id: Ecto.UUID.generate()}
    assert {:error, %{code: :claude_coach}} = Client.chat([], ledger: ledger)
    assert llm_call_count(scope) == 0
  end

  test "a session done or logged by a user Claude coaches queues none of the app's coach",
       %{user: user} do
    scope = Scope.for_user(coached_by_claude(user))
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

  test "Home for a user Claude coaches shows Claude's note and points to Claude, with no message box",
       %{conn: conn, user: user} do
    user = coached_by_claude(user)
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

    assert Summary.get(scope).source == :claude

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    assert has_element?(view, "#home-coach-note", "Two sessions left; keep Thursday easy.")
    assert has_element?(view, "#home-coach-week")
    assert has_element?(view, "#home-coach-claude", "MCP connection")
    refute has_element?(view, "#home-coach-message-form")
    refute has_element?(view, ".coach-quick-replies")
  end

  test "Home for a user Claude coaches points to Claude even before Claude wrote anything",
       %{conn: conn, user: user} do
    user = coached_by_claude(user)
    free_form_session_fixture(user, %{duration_sec_actual: 1_200})

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    assert has_element?(view, "#home-coach-panel #home-coach-claude")
    assert all_enqueued(worker: SummaryJob) == []
  end

  test "a user Claude coaches can start and switch the workout, but not ask the app to design one",
       %{conn: conn, user: user} do
    user = coached_by_claude(user)

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    assert has_element?(view, "#home-action[data-primary-action=start]")
    assert has_element?(view, "#home-title-action")
    assert has_element?(view, "#home-workout-claude", "MCP connection")
    refute has_element?(view, "#home-edit-workout")
    refute has_element?(view, "#home-new-workout")

    # A stale page's event changes nothing.
    render_click(view, "new_workout", %{})
    refute has_element?(view, "#home-new-reps")
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
