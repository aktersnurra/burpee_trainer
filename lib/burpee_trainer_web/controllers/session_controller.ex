defmodule BurpeeTrainerWeb.SessionController do
  use BurpeeTrainerWeb, :controller

  alias BurpeeTrainerWeb.Auth

  def new(conn, _params) do
    render(conn, :new)
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out.")
    |> Auth.log_out_user()
  end
end
