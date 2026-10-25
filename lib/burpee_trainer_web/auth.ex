defmodule BurpeeTrainerWeb.Auth do
  @moduledoc """
  Session plumbing for authentication. The session stores a `:user_id`
  after login; `BurpeeTrainerWeb.OidcController` is what establishes it,
  via Pocket ID.

  Exposes both plug helpers for the regular pipeline and a LiveView
  `on_mount/4` hook that enforces authentication on `live_session`
  scopes.
  """

  use BurpeeTrainerWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias BurpeeTrainer.{Accounts, Levels, Workouts}
  alias BurpeeTrainer.Accounts.Scope

  @session_key :user_id

  @doc """
  Plug that loads the current user from the session into `conn.assigns`,
  as `:current_scope`. Leaves `:current_scope` as `nil` when no session.
  """
  def fetch_current_scope(conn, _opts) do
    user =
      case get_session(conn, @session_key) do
        nil -> nil
        user_id -> Accounts.get_user(user_id)
      end

    assign(conn, :current_scope, Scope.for_user(user))
  end

  @doc """
  Plug that requires an authenticated user, redirecting to `/login` when no
  user is present.

  No flash: opening the app logged out is the ordinary first visit, and the
  login page already says what to do. An error toast there reads as a
  failure when nothing has gone wrong.
  """
  def require_authenticated_user(conn, _opts) do
    case conn.assigns[:current_scope] do
      nil ->
        conn
        |> redirect(to: ~p"/login")
        |> halt()

      _user ->
        conn
    end
  end

  @doc "Require authentication without disguising an API failure as a successful login page."
  def require_authenticated_json_user(%{assigns: %{current_scope: nil}} = conn, _opts) do
    conn |> put_status(:unauthorized) |> json(%{error: "authentication_required"}) |> halt()
  end

  def require_authenticated_json_user(conn, _opts), do: conn

  @doc """
  Plug that redirects already-authenticated users away from pages that
  only make sense when logged out (like `/login`).
  """
  def redirect_if_user_is_authenticated(conn, _opts) do
    case conn.assigns[:current_scope] do
      nil ->
        conn

      _scope ->
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
  LiveView on_mount hook: loads `:current_scope` into socket assigns and
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
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}

      _ ->
        user = provision_browser_timezone(user, socket)
        scope = Scope.for_user(user)
        level = scope |> Workouts.list_sessions() |> Levels.current_level()

        {:cont,
         socket
         |> Phoenix.Component.assign(:current_scope, scope)
         |> Phoenix.Component.assign(:current_level, level)}
    end
  end

  defp provision_browser_timezone(user, socket) do
    case Phoenix.LiveView.get_connect_params(socket) do
      %{"timezone" => timezone} when is_binary(timezone) ->
        case Accounts.update_timezone(user, timezone) do
          {:ok, updated_user} -> updated_user
          {:error, _changeset} -> user
        end

      _connect_params ->
        user
    end
  end
end
