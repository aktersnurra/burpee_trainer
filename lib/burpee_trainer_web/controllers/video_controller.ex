defmodule BurpeeTrainerWeb.VideoController do
  use BurpeeTrainerWeb, :controller

  def stream(conn, %{"filename" => filename}) do
    if conn.assigns[:current_user] do
      conn
      |> put_resp_header("x-accel-redirect", "/protected-videos/#{filename}")
      |> put_resp_header("content-type", "video/mp4")
      |> send_resp(200, "")
    else
      redirect(conn, to: ~p"/login")
    end
  end
end
