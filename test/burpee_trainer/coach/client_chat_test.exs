defmodule BurpeeTrainer.Coach.ClientChatTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.Client

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

    assert llm_call_count(scope) == 1
  end

  test "a programming error crashes instead of reporting an unavailable provider" do
    scope = scope_fixture()

    assert_raise Protocol.UndefinedError, fn ->
      Client.chat([%{role: "user", content: {:not, :json}}],
        config: @config,
        req: Req.new(plug: {Req.Test, __MODULE__}),
        ledger: %{scope: scope, purpose: "layout", run_id: Ecto.UUID.generate()}
      )
    end
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

  test "a streamed answer is heard as it grows, without its thinking, and recorded once" do
    scope = scope_fixture()
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"stream" => true} = Jason.decode!(body)

      BurpeeTrainer.ProviderStream.reply(
        conn,
        %{
          "choices" => [%{"message" => %{"content" => ~s({"reply":"Keep Thursday light."})}}],
          "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 9}
        },
        body
      )
    end)

    assert {:ok, %{content: %{"reply" => "Keep Thursday light."}, tool_calls: []}} =
             Client.chat([%{role: "user", content: "hi"}],
               config: @config,
               req: Req.new(plug: {Req.Test, __MODULE__}),
               response_format: {"coach_reply", %{type: "object"}},
               on_content: &send(parent, {:content, &1}),
               ledger: %{scope: scope, purpose: "coach_message", run_id: Ecto.UUID.generate()}
             )

    assert_received {:content, ~s({"reply":"Keep Thursday light."})}
    refute_received {:content, "Thinking." <> _}

    assert [%{prompt_tokens: 12, completion_tokens: 9, outcome: "ok"}] =
             Repo.all(BurpeeTrainer.Coach.LlmCall)
  end

  test "a stream cut short is an invalid answer, not a partial one" do
    scope = scope_fixture()

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(
        200,
        ~s(data: {"choices":[{"delta":{"content":"{\\"reply\\":\\"Hal"}}]}\n\n)
      )
    end)

    assert {:error, %{code: :invalid_provider_response}} =
             Client.chat([%{role: "user", content: "hi"}],
               config: @config,
               req: Req.new(plug: {Req.Test, __MODULE__}),
               on_content: fn _ -> :ok end,
               ledger: %{scope: scope, purpose: "coach_message", run_id: Ecto.UUID.generate()}
             )
  end
end
