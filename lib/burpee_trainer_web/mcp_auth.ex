defmodule BurpeeTrainerWeb.McpAuth do
  @moduledoc """
  Signs in a request to `/mcp` from its Bearer token. A token that does not verify, or
  whose subject is no user of the app, gets a 401 that points at the protected-resource
  metadata, so Claude can find Pocket ID and sign in. Accounts are made by signing in to
  the app, never here. The token is never logged.
  """

  import Plug.Conn

  alias BurpeeTrainer.Accounts
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Mcp.Token

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:enabled, true} <- {:enabled, Token.enabled?()},
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         token = String.trim(token),
         true <- token != "",
         {:ok, sub} <- Token.impl().verify(token),
         %Accounts.User{} = user <- Accounts.get_user_by_oidc_sub(sub) do
      assign(conn, :current_scope, Scope.for_user(user))
    else
      {:enabled, false} ->
        conn |> send_resp(404, "") |> halt()

      refusal ->
        Logger.info("mcp_unauthorized reason=#{reason(refusal)}")

        conn
        |> put_resp_header("www-authenticate", ~s(Bearer resource_metadata="#{metadata_url()}"))
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "invalid_token"}))
        |> halt()
    end
  end

  def metadata_url, do: BurpeeTrainerWeb.Endpoint.url() <> "/.well-known/oauth-protected-resource"

  defp reason({:error, reason}) when is_atom(reason), do: reason
  defp reason({:error, {reason, _, _}}) when is_atom(reason), do: reason
  defp reason({:error, _}), do: :invalid_token
  defp reason(nil), do: :unknown_subject
  defp reason(_), do: :missing_bearer
end
