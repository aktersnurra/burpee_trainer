defmodule BurpeeTrainerWeb.StatsLive do
  @moduledoc "Compatibility route for links to the former standalone Stats screen."

  use BurpeeTrainerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, redirect(socket, to: ~p"/?history=1")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={assigns[:current_scope]}>
      <p>Opening History…</p>
    </Layouts.app>
    """
  end
end
