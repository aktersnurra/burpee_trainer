defmodule BurpeeTrainerWeb.McpAuthTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainerWeb.McpAuth

  defmodule StubToken do
    @behaviour BurpeeTrainer.Mcp.Token
    @impl true
    def verify("valid:" <> sub), do: {:ok, sub}
    def verify(_), do: {:error, :invalid}
  end

  setup do
    previous =
      {Application.get_env(:burpee_trainer, :mcp),
       Application.get_env(:burpee_trainer, :mcp_token_module)}

    Application.put_env(:burpee_trainer, :mcp, audience: "claude-burpee")
    Application.put_env(:burpee_trainer, :mcp_token_module, StubToken)

    on_exit(fn ->
      {mcp, module} = previous
      restore(:mcp, mcp)
      restore(:mcp_token_module, module)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:burpee_trainer, key)
  defp restore(key, value), do: Application.put_env(:burpee_trainer, key, value)

  defp metadata_url,
    do: BurpeeTrainerWeb.Endpoint.url() <> "/.well-known/oauth-protected-resource"

  defp authenticate(conn, header) do
    conn
    |> then(&if header, do: put_req_header(&1, "authorization", header), else: &1)
    |> McpAuth.call(McpAuth.init([]))
  end

  test "the metadata names /mcp as the resource and Pocket ID as its authorization server",
       %{conn: conn} do
    for path <- [
          "/.well-known/oauth-protected-resource",
          "/.well-known/oauth-protected-resource/mcp"
        ] do
      body = conn |> recycle() |> get(path) |> json_response(200)

      assert body["resource"] == BurpeeTrainerWeb.Endpoint.url() <> "/mcp"

      assert body["authorization_servers"] == [
               Application.fetch_env!(:burpee_trainer, :oidc)[:issuer]
             ]

      assert body["bearer_methods_supported"] == ["header"]
      assert "openid" in body["scopes_supported"]
    end
  end

  test "without an audience configured there is no metadata", %{conn: conn} do
    Application.put_env(:burpee_trainer, :mcp, [])
    assert conn |> get("/.well-known/oauth-protected-resource") |> response(404)
  end

  test "a valid token for a known user signs in as that user", %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.link_oidc_sub(user, "sub-#{user.id}")

    conn = authenticate(conn, "Bearer valid:sub-#{user.id}")

    refute conn.halted
    assert conn.assigns.current_scope.user.id == user.id
  end

  test "a user blocked or removed in Pocket ID cannot use /mcp", %{conn: conn} do
    user = user_fixture()
    {:ok, user} = BurpeeTrainer.Accounts.link_oidc_sub(user, "sub-#{user.id}")

    for access <- [:disabled, :removed] do
      user |> Ecto.Changeset.change(access: access) |> BurpeeTrainer.Repo.update!()
      conn = conn |> recycle() |> authenticate("Bearer valid:sub-#{user.id}")
      assert conn.halted and conn.status == 401, "#{access} signed in"
    end
  end

  test "no token, a bad token, or a stranger is turned away with where to sign in",
       %{conn: conn} do
    for header <- [nil, "Basic abc", "Bearer ", "Bearer nope", "Bearer valid:nobody"] do
      conn = conn |> recycle() |> authenticate(header)

      assert conn.halted, "let in #{inspect(header)}"
      assert conn.status == 401

      assert get_resp_header(conn, "www-authenticate") ==
               [~s(Bearer resource_metadata="#{metadata_url()}")]

      assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"
    end
  end

  test "with MCP off every request is a 404", %{conn: conn} do
    Application.put_env(:burpee_trainer, :mcp, [])
    conn = authenticate(conn, "Bearer valid:anyone")
    assert conn.halted
    assert conn.status == 404
  end
end
