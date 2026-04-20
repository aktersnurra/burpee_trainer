defmodule BurpeeTrainerWeb.PageController do
  use BurpeeTrainerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
