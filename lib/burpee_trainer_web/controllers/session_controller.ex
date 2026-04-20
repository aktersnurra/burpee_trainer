defmodule BurpeeTrainerWeb.SessionController do
  use BurpeeTrainerWeb, :controller

  alias BurpeeTrainer.Accounts
  alias BurpeeTrainerWeb.Auth

  def new(conn, _params) do
    render(conn, :new, error_message: nil, username: "")
  end

  def create(conn, %{"user" => %{"username" => username, "password" => password}}) do
    case Accounts.authenticate_user(username, password) do
      {:ok, user} ->
        conn
        |> Auth.log_in_user(user)
        |> put_flash(:info, "Welcome back, #{user.username}.")
        |> redirect(to: ~p"/")

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "Invalid username or password.")
        |> render(:new, error_message: "Invalid username or password.", username: username)
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out.")
    |> Auth.log_out_user()
  end
end
