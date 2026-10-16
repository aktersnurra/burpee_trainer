defmodule BurpeeTrainer.Mcp.Token do
  @moduledoc """
  Verifies the Bearer tokens Claude sends to `/mcp`. Pocket ID is the authorization
  server; the app only checks what it issued: the signature against the issuer's keys
  (cached by the login's provider worker, refetched on an unknown key), the issuer, an
  audience that is exactly the MCP client's, expiry, and a subject.

  MCP is off until `config :burpee_trainer, :mcp, audience: ...` is set.
  """

  alias BurpeeTrainer.Auth.Oidc

  @callback verify(token :: String.t()) :: {:ok, subject :: String.t()} | {:error, term()}

  @behaviour __MODULE__

  def impl, do: Application.get_env(:burpee_trainer, :mcp_token_module, __MODULE__)

  def config, do: Application.get_env(:burpee_trainer, :mcp, [])

  @spec enabled?(keyword()) :: boolean()
  def enabled?(config \\ config()) do
    audience = config[:audience]
    is_binary(audience) and audience != ""
  end

  @impl __MODULE__
  def verify(token) when is_binary(token) do
    provider = Oidc.provider_name()

    with true <- enabled?() || {:error, :mcp_disabled},
         {:ok, context} <-
           Oidcc.ClientContext.from_configuration_worker(
             provider,
             config()[:audience],
             :unauthenticated
           ) do
      validate(token, context, :oidcc_jwt_util.refresh_jwks_fun(provider))
    end
  end

  @doc "Validates a token against a client context whose `client_id` is the MCP audience."
  @spec validate(String.t(), Oidcc.ClientContext.t(), function() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def validate(token, %Oidcc.ClientContext{} = context, refresh_jwks \\ nil)
      when is_binary(token) do
    opts =
      %{
        signing_algs: signing_algs(context),
        trusted_audiences: []
      }
      |> then(&if refresh_jwks, do: Map.put(&1, :refresh_jwks, refresh_jwks), else: &1)

    case Oidcc.Token.validate_jwt(token, context, opts) do
      {:ok, %{"sub" => sub}} when is_binary(sub) and sub != "" -> {:ok, sub}
      {:ok, _claims} -> {:error, :missing_subject}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # JOSE raises on input that is not a compact JWS at all.
    _ -> {:error, :malformed_token}
  end

  defp signing_algs(%Oidcc.ClientContext{provider_configuration: configuration}) do
    case configuration.id_token_signing_alg_values_supported do
      [_ | _] = algs -> algs
      _ -> ["RS256"]
    end
  end
end
