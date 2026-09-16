defmodule BurpeeTrainerWeb.LegacyPageController do
  use BurpeeTrainerWeb, :controller

  def home(conn, _params), do: redirect(conn, to: ~p"/")
end
