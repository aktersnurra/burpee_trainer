defmodule BurpeeTrainer.Mcp.AnalyticsTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Analytics.{Output, Schema, Trace}
  alias BurpeeTrainer.Mcp
  alias BurpeeTrainer.Mcp.Tools.Analyze

  @query %{
    "action" => "query",
    "interpretation" => "owned count",
    "intent" => "count",
    "sql" => "SELECT count(*) AS n FROM sessions"
  }
  @final %{
    "action" => "final",
    "output" => %{
      "status" => "answered",
      "interpretation" => "owned count",
      "answer" => "One session",
      "findings" => [%{"text" => "One", "evidence_ids" => ["q1"]}],
      "limitations" => []
    }
  }

  setup do
    previous =
      for key <- [:llm_provider, :analytics_review, :decisions],
          into: %{},
          do: {key, Application.get_env(:burpee_trainer, key)}

    defaults = Req.default_options()

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://recorded.test/chat",
      api_key: "local",
      model: "recorded"
    )

    Application.put_env(:burpee_trainer, :analytics_review, mode: :off)
    Application.put_env(:burpee_trainer, :decisions, enabled: false)
    owner = self()

    BurpeeTrainer.ReqStub.default(fn _ ->
      send(owner, :unexpected_provider)
      raise "unexpected provider call"
    end)

    on_exit(fn ->
      Req.default_options(defaults)
      Application.delete_env(:burpee_trainer, BurpeeTrainer.ReqStub)

      Enum.each(previous, fn {key, value} ->
        if value,
          do: Application.put_env(:burpee_trainer, key, value),
          else: Application.delete_env(:burpee_trainer, key)
      end)
    end)

    %{scope: scope_fixture()}
  end

  test "listing advertises strict input and actual output without changing old metadata", %{
    scope: scope
  } do
    %{"tools" => tools} = rpc(scope, "tools/list")
    tool = Enum.find(tools, &(&1["name"] == "analyze"))
    assert tool["inputSchema"] == Analyze.schema()
    assert tool["inputSchema"]["additionalProperties"] == false
    assert tool["inputSchema"]["required"] == ["prompt"]

    assert tool["outputSchema"]["required"] |> Enum.sort() ==
             Enum.sort(~w(status interpretation answer findings evidence limitations trace_id))

    assert tool["outputSchema"]["properties"]["status"]["enum"] ==
             ~w(answered needs_clarification insufficient_data budget_exhausted)

    assert tool["annotations"] == %{"readOnlyHint" => true}
    old = Enum.find(tools, &(&1["name"] == "history_stats"))
    assert Map.keys(old) |> Enum.sort() == ~w(description inputSchema name)
  end

  test "resource is static accepted schema alongside unchanged workout format", %{scope: scope} do
    %{"resources" => resources} = rpc(scope, "resources/list")

    assert Enum.any?(
             resources,
             &(&1["uri"] == "burpee://analytics/schema" and &1["name"] == "analytics-schema")
           )

    for {uri, text} <- [
          {"burpee://analytics/schema", Schema.text()},
          {Mcp.WorkoutFormat.uri(), Mcp.WorkoutFormat.text()}
        ] do
      assert %{"contents" => [%{"uri" => ^uri, "mimeType" => "text/markdown", "text" => ^text}]} =
               rpc(scope, "resources/read", %{"uri" => uri})
    end

    assert Enum.count(Schema.columns()) == 14

    assert {:reply, %{"error" => %{"code" => -32_602}}} =
             Mcp.handle(scope, request("resources/read", %{"uri" => "unknown"}))
  end

  test "invalid args and trusted controls are rejected before any reservation", %{scope: scope} do
    invalid = [
      %{},
      %{"prompt" => ""},
      %{"prompt" => 1},
      %{"prompt" => <<255>>},
      %{"prompt" => String.duplicate("é", 2049)},
      [],
      "count"
    ]

    controls =
      ~w(user_id scope config mode timeout_ms review_mode call_budget call_allowance ledger_run_id deadline_ms)

    for args <- invalid ++ Enum.map(controls, &%{"prompt" => "count", &1 => 1}) do
      assert {:error, _} = Analyze.call(scope, args, %{})
    end

    assert llm_call_count(scope) == 0
    refute_received :unexpected_provider
  end

  test "disabled owner receives isError with zero paid reservations", %{scope: scope} do
    disabled = %{scope | user: %{scope.user | coach_enabled: false}}
    result = call(disabled)
    assert result["isError"]
    assert error_code(result) == "provider_unavailable"
    assert llm_call_count(scope) == 0
    refute_received :unexpected_provider
  end

  test "successful result preserves JSON convention, evidence and trace ownership", %{
    scope: scope
  } do
    free_form_session_fixture(scope.user)
    other = scope_fixture()
    free_form_session_fixture(other.user)
    recorded([@query, @final])
    result = call(scope)
    refute result["isError"]
    output = result["structuredContent"]
    assert Jason.decode!(hd(result["content"])["text"]) == output
    assert [%{"id" => "q1", "rows" => [[1]]}] = output["evidence"]
    assert {:ok, ^output} = Output.validate(output, ["q1"])
    assert {:ok, trace} = Trace.fetch(scope, output["trace_id"])
    assert trace["prompt"] == "count"
    assert {:error, :not_found} = Trace.fetch(other, output["trace_id"])
    assert llm_call_count(scope) == 2
    assert llm_call_count(other) == 0
  end

  test "provider and enforced reviewer failures remain real errors", %{scope: scope} do
    Application.put_env(:burpee_trainer, :llm_provider, enabled: false)
    assert error_code(call(scope)) == "provider_unavailable"

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://recorded.test/chat",
      api_key: "local",
      model: "recorded"
    )

    Application.put_env(:burpee_trainer, :analytics_review, mode: :enforce)
    recorded([@query])
    result = call(scope)
    assert result["isError"]
    assert error_code(result) == "review_unavailable"
  end

  test "unavailable executor is not an insufficient-data success", %{scope: scope} do
    assert :ok =
             Supervisor.terminate_child(
               BurpeeTrainer.Supervisor,
               BurpeeTrainer.Analytics.HelperGuardian
             )

    on_exit(fn ->
      Supervisor.restart_child(BurpeeTrainer.Supervisor, BurpeeTrainer.Analytics.HelperGuardian)
    end)

    recorded([@query])
    result = call(scope)
    assert result["isError"]
    assert error_code(result) == "executor_unavailable"
  end

  test "4096 UTF8 bytes are accepted without allowing an extra byte", %{scope: scope} do
    recorded([
      %{"action" => "clarify", "interpretation" => "ambiguous", "question" => "Which metric?"}
    ])

    assert {:ok, %{"status" => "needs_clarification"}} =
             Analyze.call(scope, %{"prompt" => String.duplicate("é", 2048)}, %{})

    assert {:error, _} =
             Analyze.call(scope, %{"prompt" => String.duplicate("é", 2048) <> "a"}, %{})

    assert llm_call_count(scope) == 1
  end

  defp recorded(responses) do
    agent = start_supervised!({Agent, fn -> responses end})

    BurpeeTrainer.ReqStub.default(fn request ->
      response = Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)

      body = %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(response)}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 10}
      }

      {request, Req.Response.new(status: 200, body: Jason.encode!(body))}
    end)
  end

  defp error_code(result),
    do: result["content"] |> hd() |> Map.fetch!("text") |> Jason.decode!() |> Map.fetch!("code")

  defp call(scope),
    do: rpc(scope, "tools/call", %{"name" => "analyze", "arguments" => %{"prompt" => "count"}})

  defp rpc(scope, method, params \\ %{}) do
    {:reply, %{"result" => result}} = Mcp.handle(scope, request(method, params))
    result
  end

  defp request(method, params),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
end
