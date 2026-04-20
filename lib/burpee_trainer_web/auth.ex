defmodule BurpeeTrainerWeb.Auth do
  @moduledoc """
  Hand-rolled session auth. Single user, bcrypt password hashing, the
  session stores a `:user_id` after login.

  Exposes both plug helpers for the regular pipeline and a LiveView
  `on_mount/4` hook that enforces authentication on `live_session`
  scopes.
  """

  use BurpeeTrainerWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias BurpeeTrainer.Accounts

  @session_key :user_id

  @doc """
  Plug that loads the current user from the session into `conn.assigns`,
  as `:current_user`. Leaves `:current_user` as `nil` when no session.
  """
  def fetch_current_user(conn, _opts) do
    user =
      case get_session(conn, @session_key) do
        nil -> nil
        user_id -> Accounts.get_user(user_id)
      end

    assign(conn, :current_user, user)
  end

  @doc """
  Plug that requires an authenticated user. Redirects to `/login` with a
  flash if no user is present.
  """
  def require_authenticated_user(conn, _opts) do
    case conn.assigns[:current_user] do
      nil ->
        conn
        |> put_flash(:error, "You must log in to continue.")
        |> redirect(to: ~p"/login")
        |> halt()

      _user ->
        conn
    end
  end

  @doc """
  Plug that redirects already-authenticated users away from pages that
  only make sense when logged out (like `/login`).
  """
  def redirect_if_user_is_authenticated(conn, _opts) do
    case conn.assigns[:current_user] do
      nil ->
        conn

      _user ->
        conn
        |> redirect(to: ~p"/")
        |> halt()
    end
  end

  @doc """
  Log the user in. Rotates the session id to prevent fixation.
  """
  def log_in_user(conn, user) do
    conn
    |> renew_session()
    |> put_session(@session_key, user.id)
    |> configure_session(renew: true)
  end

  @doc """
  Drop the session (logout).
  """
  def log_out_user(conn) do
    conn
    |> renew_session()
    |> redirect(to: ~p"/login")
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  @doc """
  LiveView on_mount hook: loads `:current_user` into socket assigns and
  halts with a redirect when no user is present.
  """
  def on_mount(:require_authenticated_user, _params, session, socket) do
    user =
      case session[Atom.to_string(@session_key)] do
        nil -> nil
        user_id -> Accounts.get_user(user_id)
      end

    case user do
      nil ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must log in to continue.")
          |> Phoenix.LiveView.redirect(to: ~p"/login")

        {:halt, socket}

      _ ->
        {:cont, Phoenix.Component.assign(socket, :current_user, user)}
    end
  end
end
