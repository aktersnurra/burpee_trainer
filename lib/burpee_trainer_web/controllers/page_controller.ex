defmodule BurpeeTrainerWeb.PageController do
  use BurpeeTrainerWeb, :controller

  alias BurpeeTrainer.{Levels, Workouts}

  def home(conn, _params) do
    level =
      case conn.assigns[:current_user] do
        nil -> nil
        user -> user |> Workouts.list_sessions() |> Levels.current_level()
      end

    render(conn, :home, current_level: level)
  end
end
