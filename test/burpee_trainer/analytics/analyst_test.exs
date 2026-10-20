defmodule BurpeeTrainer.Analytics.AnalystTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Analytics
  alias BurpeeTrainer.Analytics.{CallBudget, Trace}
  alias BurpeeTrainer.AnalyticsProviderPlug, as: Provider
  @config [enabled: true, url: "https://recorded.test/chat", api_key: "local", model: "recorded"]
  @query %{
    "action" => "query",
    "interpretation" => "session count",
    "intent" => "count",
    "sql" => "SELECT count(*) AS n FROM sessions"
  }
  @final %{
    "action" => "final",
    "output" => %{
      "status" => "answered",
      "interpretation" => "session count",
      "answer" => "No sessions",
      "findings" => [%{"text" => "Zero", "evidence_ids" => ["q1"]}],
      "limitations" => []
    }
  }

  defp opts(responses, extra \\ []),
    do:
      Keyword.merge([config: @config, req: Provider.request(responses), review_mode: :off], extra)

  test "real parser/query loop creates evidence and private inspectable trace" do
    scope = scope_fixture()

    assert {:ok, output} =
             Analytics.analyze(scope, "How many completed sessions?", opts([@query, @final]))

    assert output["status"] == "answered"
    assert [%{"id" => "q1", "rows" => [[0]]}] = output["evidence"]
    assert {:ok, trace} = Trace.fetch(scope, output["trace_id"])
    assert trace["prompt"] == "How many completed sessions?"
    refute Map.has_key?(trace, "snapshot")
    assert {:error, :not_found} = Trace.fetch(scope_fixture(), output["trace_id"])
  end

  test "ordinary SQL errors can be repaired but errors cannot be cited" do
    bad = Map.put(@query, "sql", "SELECT missing FROM sessions")

    assert {:ok, output} =
             Analytics.analyze(scope_fixture(), "count", opts([bad, @query, @final]))

    assert output["status"] == "answered"
    assert [_] = output["evidence"]
  end

  test "denied attempts exhaust without fabricated evidence" do
    bad = Map.put(@query, "sql", "PRAGMA user_version")
    assert {:ok, output} = Analytics.analyze(scope_fixture(), "count", opts([bad, bad, bad]))
    assert output["status"] == "budget_exhausted"
    assert output["evidence"] == []
  end

  test "clarification and sparse abstention do not invent successful evidence" do
    assert {:ok, output} =
             Analytics.analyze(
               scope_fixture(),
               "Have I improved?",
               opts([
                 %{
                   "action" => "clarify",
                   "interpretation" => "ambiguous",
                   "question" => "Volume, frequency or pace?"
                 }
               ])
             )

    assert output["status"] == "needs_clarification"

    sparse =
      put_in(@final, ["output"], %{
        "status" => "insufficient_data",
        "interpretation" => "pace",
        "answer" => "No comparable sessions",
        "findings" => [],
        "limitations" => ["Sparse data"]
      })

    assert {:ok, %{"status" => "insufficient_data"}} =
             Analytics.analyze(scope_fixture(), "pace", opts([sparse]))
  end

  test "forgery and malformed actions fail explicitly, disabled owner reserves nothing" do
    scope = scope_fixture()

    assert {:error, %{code: :invalid_analytics_output}} =
             Analytics.analyze(scope, "count", opts([@final]))

    assert {:error, %{code: :invalid_analyst_action}} =
             Analytics.analyze(
               scope,
               "count",
               opts([%{"action" => "query", "sql" => "SELECT 1"}])
             )

    disabled = scope_fixture()
    user = disabled.user |> Ecto.Changeset.change(coach_enabled: false) |> Repo.update!()
    disabled = %{disabled | user: user}

    assert {:error, %{code: :provider_unavailable}} =
             Analytics.analyze(disabled, "count", opts([]))

    assert llm_call_count(disabled) == 0
  end

  test "one global remaining reservation cannot replenish for review, repair or another arm" do
    scope = scope_fixture()
    budget = CallBudget.new(scope, 1)

    controls = [
      call_budget: budget,
      call_allowance: 1,
      review_mode: :enforce,
      review: [config: @config, req: Provider.request([])]
    ]

    assert {:ok, %{"status" => "budget_exhausted"}} =
             Analytics.analyze(scope, "count", opts([@query], controls))

    assert {:ok, %{reservations: 1, remaining: 0, inflight: 0}} = CallBudget.usage(scope, budget)

    assert {:ok, %{"status" => "budget_exhausted"}} =
             Analytics.analyze(scope, "count", opts([], controls))

    assert {:ok, %{reservations: 1}} = CallBudget.usage(scope, budget)
  end

  test "independent run watchdog kills a stalled analysis worker without invented trace" do
    scope = scope_fixture()
    owner = self()

    req =
      Req.new(
        adapter: fn request ->
          send(owner, :run_transport_started)

          receive do
            :never -> {request, Req.Response.new(status: 200)}
          end
        end
      )

    caller =
      start_supervised!(
        {Task,
         fn ->
           result =
             Analytics.analyze(scope, "count",
               config: @config,
               req: req,
               review_mode: :off,
               run_timeout_ms: 6200
             )

           send(owner, {:run_watchdog_result, result})
         end},
        id: :run_watchdog
      )

    assert_receive :run_transport_started

    worker =
      Enum.find(Task.Supervisor.children(BurpeeTrainer.Analytics.RunSupervisor), fn pid ->
        case Process.info(pid, :current_stacktrace) do
          {:current_stacktrace, stack} ->
            Enum.any?(stack, fn {module, _, _, _} ->
              module == BurpeeTrainer.Coach.Client.Deadline
            end)

          _ ->
            false
        end
      end)

    assert is_pid(worker)
    :erlang.suspend_process(worker)
    worker_ref = Process.monitor(worker)
    caller_ref = Process.monitor(caller)
    assert_receive {:run_watchdog_result, {:error, %{code: :run_timeout}}}, 6800
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert llm_call_count(scope) == 1
  end

  test "zero allowance, foreign owner and invalid timezone fail without provider calls" do
    scope = scope_fixture()
    budget = CallBudget.new(scope, 0)

    assert {:ok, %{"status" => "budget_exhausted"}} =
             Analytics.analyze(scope, "count", opts([], call_budget: budget, call_allowance: 0))

    assert {:error, %{code: :budget_owner_mismatch}} =
             Analytics.analyze(scope_fixture(), "count", opts([], call_budget: budget))

    bad = %{scope | user: %{scope.user | timezone: "Missing/Timezone"}}
    assert {:error, %{code: :invalid_timezone}} = Analytics.analyze(bad, "count", opts([]))
    assert llm_call_count(scope) == 0
  end

  test "trace storage failure is explicit instead of claiming inspectability" do
    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER analytics_trace_failure BEFORE INSERT ON analytics_traces BEGIN SELECT RAISE(ABORT, 'trace write failed'); END",
      []
    )

    clarify = %{
      "action" => "clarify",
      "interpretation" => "ambiguous",
      "question" => "Which metric?"
    }

    assert {:error, %{code: :trace_unavailable}} =
             Analytics.analyze(scope_fixture(), "improved", opts([clarify]))
  end

  test "unavailable provider never becomes an insufficient data answer" do
    assert {:error, %{code: :provider_unavailable}} =
             Analytics.analyze(scope_fixture(), "count",
               config: [enabled: false],
               review_mode: :off
             )
  end

  test "helper unavailability remains an explicit infrastructure error" do
    assert :ok =
             Supervisor.terminate_child(
               BurpeeTrainer.Supervisor,
               BurpeeTrainer.Analytics.HelperGuardian
             )

    on_exit(fn ->
      Supervisor.restart_child(BurpeeTrainer.Supervisor, BurpeeTrainer.Analytics.HelperGuardian)
    end)

    assert {:error, %{code: :executor_unavailable}} =
             Analytics.analyze(scope_fixture(), "count", opts([@query]))
  end
end
