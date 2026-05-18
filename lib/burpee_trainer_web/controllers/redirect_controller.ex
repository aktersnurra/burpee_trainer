defmodule BurpeeTrainerWeb.RedirectController do
  use BurpeeTrainerWeb, :controller

  def plans(conn, _), do: redirect(conn, to: ~p"/workouts")
  def videos(conn, _), do: redirect(conn, to: ~p"/workouts")
  def log(conn, _), do: redirect(conn, to: ~p"/stats")
  def history(conn, _), do: redirect(conn, to: ~p"/stats")
  def goals(conn, _), do: redirect(conn, to: ~p"/stats")
end
