defmodule BurpeeTrainerWeb.LogFormComponent do
  use BurpeeTrainerWeb, :live_component

  @impl true
  def mount(socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h2 class="text-lg font-semibold mb-4">Log session</h2>
      <p class="text-sm text-base-content/50">Form coming soon.</p>
    </div>
    """
  end
end
