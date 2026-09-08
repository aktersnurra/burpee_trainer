defmodule BurpeeTrainerWeb.OidcController do
  @moduledoc """
  Authorization-code-with-PKCE login against Pocket ID.

  This controller never creates a user. An ID token whose `sub` is not
  already linked to a local account is rejected — linking is done offline
  with `mix burpee_trainer.link_oidc`.
  """

  use BurpeeTrainerWeb, :controller

  alias BurpeeTrainer.Accounts
  alias BurpeeTrainer.Auth.Oidc
  alias BurpeeTrainerWeb.Auth

  require Logger

  def request(conn, _params) do
    state = random_token()
    verifier = random_token()

    case Oidc.impl().authorization_url(state, verifier) do
      {:ok, url} ->
        conn
        |> put_session(:oidc_state, state)
        |> put_session(:oidc_pkce_verifier, verifier)
        |> redirect(external: url)

      {:error, reason} ->
        Logger.error("OIDC authorization URL failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Could not reach the login provider.")
        |> redirect(to: ~p"/login")
    end
  end

  def callback(conn, %{"error" => error}) do
    Logger.warning("OIDC provider returned error: #{inspect(error)}")
    deny(conn, "Login was cancelled or denied.")
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    session_state = get_session(conn, :oidc_state)
    verifier = get_session(conn, :oidc_pkce_verifier)

    cond do
      is_nil(session_state) or is_nil(verifier) ->
        deny(conn, "Your login session expired. Please try again.")

      not secure_compare(session_state, state) ->
        Logger.warning("OIDC state mismatch")
        deny(conn, "Login verification failed. Please try again.")

      true ->
        exchange(conn, code, verifier)
    end
  end

  def callback(conn, _params), do: deny(conn, "Invalid login response.")

  defp exchange(conn, code, verifier) do
    case Oidc.impl().fetch_claims(code, verifier) do
      {:ok, claims} ->
        resolve(conn, claims)

      {:error, reason} ->
        Logger.error("OIDC token exchange failed: #{inspect(reason)}")
        deny(conn, "Could not complete login. Please try again.")
    end
  end

  defp resolve(conn, claims) do
    sub = Map.get(claims, "sub")

    case Accounts.get_user_by_oidc_sub(sub) do
      nil ->
        Logger.warning("OIDC login for unlinked sub #{inspect(sub)}")

        deny(
          conn,
          "This identity is not linked to an account. " <>
            "Run mix burpee_trainer.link_oidc to link it."
        )

      user ->
        conn
        |> clear_oidc_session()
        |> Auth.log_in_user(user)
        |> put_flash(:info, "Welcome back, #{user.username}.")
        |> redirect(to: ~p"/")
    end
  end

  defp deny(conn, message) do
    conn
    |> clear_oidc_session()
    |> put_flash(:error, message)
    |> redirect(to: ~p"/login")
  end

  defp clear_oidc_session(conn) do
    conn
    |> delete_session(:oidc_state)
    |> delete_session(:oidc_pkce_verifier)
  end

  defp random_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    Plug.Crypto.secure_compare(a, b)
  end

  defp secure_compare(_a, _b), do: false
end
