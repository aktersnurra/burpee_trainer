defmodule BurpeeTrainerWeb.DevSessionController do
  @moduledoc """
  Development-only sign-in that skips Pocket ID. Routed only when `:dev_routes` is on.
  """

  use BurpeeTrainerWeb, :controller

  alias BurpeeTrainer.Accounts
  alias BurpeeTrainerWeb.Auth

  @username "dev"

  def create(conn, _params) do
    user =
      Accounts.get_user_by_username(@username) ||
        with {:ok, user} <- Accounts.create_user(%{username: @username}), do: user

    conn
    |> Auth.log_in_user(user)
    |> redirect(to: ~p"/")
  end
end
