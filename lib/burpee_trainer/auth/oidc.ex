defmodule BurpeeTrainer.Auth.Oidc do
  @moduledoc """
  Thin wrapper over `oidcc` for the authorization-code-with-PKCE flow.

  Exists as a behaviour so tests can swap in a stub: the callback
  controller must be testable without talking to a real OIDC provider.
  Configure the implementation with:

      config :burpee_trainer, :oidc_module, MyStub
  """

  @provider_name BurpeeTrainer.Auth.OidcProvider

  @type claims :: %{String.t() => term()}

  @callback authorization_url(state :: String.t(), pkce_verifier :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @callback fetch_claims(code :: String.t(), pkce_verifier :: String.t()) ::
              {:ok, claims()} | {:error, term()}

  @doc """
  The configured implementation. Defaults to this module.
  """
  def impl, do: Application.get_env(:burpee_trainer, :oidc_module, __MODULE__)

  @doc """
  The name the provider-configuration worker is registered under.
  """
  def provider_name, do: @provider_name

  @doc """
  OIDC settings from application config.
  """
  def config, do: Application.fetch_env!(:burpee_trainer, :oidc)

  @doc """
  True when OIDC is configured well enough to attempt a login.
  """
  def configured? do
    cfg = Application.get_env(:burpee_trainer, :oidc, [])

    present?(cfg[:issuer]) and present?(cfg[:client_id]) and present?(cfg[:client_secret])
  end

  defp present?(value), do: is_binary(value) and value != ""

  @behaviour __MODULE__

  @impl __MODULE__
  def authorization_url(state, pkce_verifier) do
    cfg = config()

    Oidcc.create_redirect_url(
      provider_name(),
      cfg[:client_id],
      cfg[:client_secret],
      %{
        redirect_uri: cfg[:redirect_uri],
        scopes: ["openid", "profile"],
        state: state,
        pkce_verifier: pkce_verifier,
        require_pkce: true
      }
    )
    |> case do
      {:ok, url} -> {:ok, IO.iodata_to_binary(url)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl __MODULE__
  def fetch_claims(code, pkce_verifier) do
    cfg = config()

    case Oidcc.retrieve_token(
           code,
           provider_name(),
           cfg[:client_id],
           cfg[:client_secret],
           %{
             redirect_uri: cfg[:redirect_uri],
             pkce_verifier: pkce_verifier,
             require_pkce: true
           }
         ) do
      {:ok, %Oidcc.Token{id: %Oidcc.Token.Id{claims: claims}}} -> {:ok, claims}
      {:ok, _token} -> {:error, :missing_id_token}
      {:error, reason} -> {:error, reason}
    end
  end
end
