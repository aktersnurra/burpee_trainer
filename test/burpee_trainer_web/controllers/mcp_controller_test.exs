defmodule BurpeeTrainerWeb.McpControllerTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures

  defmodule StubToken do
    @behaviour BurpeeTrainer.Mcp.Token
    @impl true
    def verify("valid:" <> sub), do: {:ok, sub}
    def verify(_), do: {:error, :invalid}
  end

  setup %{conn: conn} do
    previous =
      {Application.get_env(:burpee_trainer, :mcp),
       Application.get_env(:burpee_trainer, :mcp_token_module)}

    Application.put_env(:burpee_trainer, :mcp, audience: "claude-burpee")
    Application.put_env(:burpee_trainer, :mcp_token_module, StubToken)

    on_exit(fn ->
      {mcp, module} = previous

      if mcp,
        do: Application.put_env(:burpee_trainer, :mcp, mcp),
        else: Application.delete_env(:burpee_trainer, :mcp)

      if module,
        do: Application.put_env(:burpee_trainer, :mcp_token_module, module),
        else: Application.delete_env(:burpee_trainer, :mcp_token_module)
    end)

    {:ok, user} = BurpeeTrainer.Accounts.link_oidc_sub(user_fixture(), "sub-mcp")

    conn =
      conn
      |> put_req_header("authorization", "Bearer valid:sub-mcp")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn, user: user}
  end

  test "a signed-in client initializes and lists tools over POST /mcp", %{conn: conn} do
    body =
      conn
      |> post(
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-06-18"}
        })
      )
      |> json_response(200)

    assert body["result"]["protocolVersion"] == "2025-06-18"

    body =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer valid:sub-mcp")
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}))
      |> json_response(200)

    assert is_list(body["result"]["tools"])
  end

  test "a notification is accepted with no body", %{conn: conn} do
    conn =
      post(
        conn,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      )

    assert response(conn, 202) == ""
  end

  test "a batch is refused", %{conn: conn} do
    body =
      conn
      |> post("/mcp", Jason.encode!([%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}]))
      |> json_response(200)

    assert body["error"]["code"] == -32600
  end

  test "there is no event stream", %{conn: conn} do
    assert conn |> get("/mcp") |> response(405)
  end

  test "without a token the client is told where to sign in", %{conn: conn} do
    conn =
      conn
      |> delete_req_header("authorization")
      |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}))

    assert response(conn, 401)
    assert [~s(Bearer resource_metadata=) <> _] = get_resp_header(conn, "www-authenticate")
  end
end
