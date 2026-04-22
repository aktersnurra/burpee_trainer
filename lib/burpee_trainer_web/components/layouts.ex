defmodule BurpeeTrainerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use BurpeeTrainerWeb, :html

  embed_templates "layouts/*"

  @doc """
  Main app layout. `current_user` is optional — the login page passes
  `nil` and the navigation adapts accordingly.
  """
  attr :flash, :map, required: true
  attr :current_user, :any, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-base-300 bg-base-100">
      <div class="mx-auto max-w-5xl px-4 sm:px-6 lg:px-8 flex h-14 items-center gap-6">
        <a href="/" class="font-semibold tracking-tight">BurpeeTrainer</a>

        <%= if @current_user do %>
          <nav class="flex-1 flex items-center gap-1 text-sm">
            <.nav_link href={~p"/plans"}>Plans</.nav_link>
            <.nav_link href={~p"/log"}>Log</.nav_link>
            <.nav_link href={~p"/history"}>History</.nav_link>
            <.nav_link href={~p"/goals"}>Goals</.nav_link>
          </nav>

          <div class="flex items-center gap-3">
            <span class="text-xs text-base-content/60 hidden sm:inline">
              {@current_user.username}
            </span>
            <.form for={%{}} action={~p"/logout"} method="delete" class="inline">
              <button
                type="submit"
                class="text-sm px-3 py-1.5 rounded-md border border-base-300 hover:bg-base-200 transition"
              >
                Log out
              </button>
            </.form>
          </div>
        <% else %>
          <div class="flex-1" />
        <% end %>
      </div>
    </header>

    <main class="mx-auto max-w-5xl px-4 py-10 sm:px-6 lg:px-8">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  attr :href, :string, required: true
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="px-3 py-1.5 rounded-md text-base-content/70 hover:text-base-content hover:bg-base-200 transition"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

end
