defmodule BurpeeTrainer.McpTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Mcp
  alias BurpeeTrainer.Accounts.{Scope, User}

  defmodule Echo do
    @behaviour BurpeeTrainer.Coach.Tool
    alias BurpeeTrainer.Coach.Tool
    def name, do: "echo"
    def description, do: "Says the word back."
    def schema, do: Tool.object(%{"word" => %{"type" => "string"}}, ["word"])

    def call(%Scope{user: user}, %{"word" => word} = args, _) when map_size(args) == 1,
      do: {:ok, %{"word" => word, "user_id" => user.id}}

    def call(_, _, _), do: {:error, "echo takes one word"}
  end

  @scope %Scope{user: %User{id: 7}}

  defp request(method, params \\ nil, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    |> then(&if params, do: Map.put(&1, "params", params), else: &1)
  end

  defp handle(request), do: Mcp.handle(@scope, request, [Echo])

  test "initialize answers with the version the client asked for, or the latest" do
    {:reply, %{"result" => result, "id" => 1}} =
      handle(request("initialize", %{"protocolVersion" => "2025-03-26"}))

    assert result["protocolVersion"] == "2025-03-26"
    assert result["serverInfo"]["name"] == "burpee-trainer"
    assert result["capabilities"]["tools"]

    {:reply, %{"result" => result}} =
      handle(request("initialize", %{"protocolVersion" => "1999-01-01"}))

    assert result["protocolVersion"] == Mcp.latest_protocol_version()
  end

  test "notifications get no reply, ping gets an empty result" do
    assert handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}) == :accepted
    assert {:reply, %{"result" => %{}, "id" => 3}} = handle(request("ping", nil, 3))
  end

  test "tools/list describes every registered tool with its schema" do
    {:reply, %{"result" => %{"tools" => [tool]}}} = handle(request("tools/list"))

    assert tool == %{
             "name" => "echo",
             "description" => "Says the word back.",
             "inputSchema" => Echo.schema()
           }
  end

  test "tools/call runs the tool as the signed-in user" do
    {:reply, %{"result" => result}} =
      handle(request("tools/call", %{"name" => "echo", "arguments" => %{"word" => "hi"}}))

    assert result["structuredContent"] == %{"word" => "hi", "user_id" => 7}
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert Jason.decode!(text) == result["structuredContent"]
    refute result["isError"]
  end

  test "a refused call is a tool error the model can read, not a protocol error" do
    for arguments <- [%{}, %{"word" => "hi", "extra" => 1}, nil] do
      params =
        %{"name" => "echo"}
        |> then(&if arguments, do: Map.put(&1, "arguments", arguments), else: &1)

      {:reply, %{"result" => result}} = handle(request("tools/call", params))

      assert result["isError"]
      assert [%{"type" => "text", "text" => "echo takes one word"}] = result["content"]
    end
  end

  test "unknown tools, unknown methods and malformed requests are protocol errors" do
    {:reply, %{"error" => %{"code" => -32602}}} =
      handle(request("tools/call", %{"name" => "nope", "arguments" => %{}}))

    {:reply, %{"error" => %{"code" => -32601}, "id" => 1}} = handle(request("sampling/create"))

    for bad <- [
          %{},
          %{"jsonrpc" => "1.0", "id" => 1, "method" => "ping"},
          %{"jsonrpc" => "2.0", "id" => 1}
        ] do
      assert {:reply, %{"error" => %{"code" => -32600}}} = handle(bad)
    end
  end
end
