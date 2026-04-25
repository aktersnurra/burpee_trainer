defmodule BurpeeTrainerWeb.StubLive do
  @moduledoc """
  Placeholder LiveView for sections that aren't built yet. Each route
  will be replaced as its milestone lands.
  """
  use BurpeeTrainerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_level={@current_level}>
      <div class="max-w-lg space-y-3 rounded-lg border border-dashed border-base-300 p-8 text-center">
        <h1 class="text-xl font-semibold">{page_title(@live_action)}</h1>
        <p class="text-base-content/60">This page is coming soon.</p>
      </div>
    </Layouts.app>
    """
  end

  defp page_title(:plans), do: "Plans"
  defp page_title(:log), do: "Log session"
  defp page_title(:history), do: "History"
  defp page_title(:goals), do: "Goals"
  defp page_title(_), do: "Coming soon"
end
