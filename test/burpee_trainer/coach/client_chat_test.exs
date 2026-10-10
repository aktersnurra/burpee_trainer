defmodule BurpeeTrainer.Coach.ClientChatTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.{Client, Ledger}

  @config [
    enabled: true,
    url: "https://provider.test/v1/chat/completions",
    api_key: "k",
    model: "m"
  ]

  test "sends strict tools and decodes arguments, records usage once" do
    scope = scope_fixture()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert [%{"function" => %{"name" => "history", "strict" => true}}] = request["tools"]

      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "c1",
                  "type" => "function",
                  "function" => %{"name" => "history", "arguments" => ~s({"weeks":4})}
                }
              ]
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 10}
      })
    end)

    assert {:ok,
            %{
              tool_calls: [%{id: "c1", name: "history", arguments: %{"weeks" => 4}}],
              content: nil
            }} =
             Client.chat([%{role: "user", content: "hi"}],
               config: @config,
               req: Req.new(plug: {Req.Test, __MODULE__}),
               tools: [%{name: "history", description: "d", schema: %{type: "object"}}],
               ledger: %{scope: scope, purpose: "plan_next", run_id: Ecto.UUID.generate()}
             )

    assert Ledger.calls_today(scope) == 1
  end

  test "strict JSON and invalid duplicate keys are distinguished" do
    scope = scope_fixture()

    opts = [
      config: @config,
      req: Req.new(plug: {Req.Test, __MODULE__}),
      response_format: {"answer", %{type: "object"}},
      ledger: %{scope: scope, purpose: "insight", run_id: Ecto.UUID.generate()}
    ]

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => ~s({"ok":true})}}]})
    end)

    assert {:ok, %{content: %{"ok" => true}, tool_calls: []}} = Client.chat([], opts)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => ~s({"ok":true,"ok":false})}}]
      })
    end)

    assert {:error, %{code: :invalid_provider_response}} = Client.chat([], opts)
    assert Ledger.calls_today(scope) == 2
  end

  test "a disabled provider makes no call and records no ledger row" do
    scope = scope_fixture()
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :transport)
      Req.Test.json(conn, %{})
    end)

    assert {:error, %{code: :provider_unavailable}} =
             Client.chat([],
               config: Keyword.put(@config, :enabled, false),
               req: Req.new(plug: {Req.Test, __MODULE__}),
               ledger: %{scope: scope, purpose: "plan_next", run_id: Ecto.UUID.generate()}
             )

    refute_received :transport
    assert llm_call_count(scope) == 0
  end

  test "invalid output still records supplied billing usage and cannot bypass the cost cap" do
    scope = scope_fixture()
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :transport)

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => "not JSON"}}],
        "usage" => %{"cost" => 0.7, "prompt_tokens" => 10}
      })
    end)

    opts = [
      config: @config,
      req: Req.new(plug: {Req.Test, __MODULE__}),
      response_format: {"answer", %{type: "object"}},
      budget: [daily_cost_cap_usd: 1.0, reservation_cost_usd: 0.4],
      ledger: %{scope: scope, purpose: "insight", run_id: Ecto.UUID.generate()}
    ]

    assert {:error, %{code: :invalid_provider_response}} = Client.chat([], opts)
    assert {:error, %{code: :llm_budget_exhausted}} = Client.chat([], opts)
    assert_receive :transport
    refute_received :transport

    assert [%{cost_usd: 0.7, prompt_tokens: 10, outcome: "invalid_response"}] =
             Repo.all(BurpeeTrainer.Coach.LlmCall)
  end
end
