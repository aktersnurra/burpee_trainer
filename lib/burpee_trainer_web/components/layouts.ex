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
  attr :current_level, :atom, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-[#1E2535] bg-base-100">
      <div class="mx-auto max-w-2xl px-4 sm:px-6 flex h-[52px] items-center gap-6">
        <.link navigate={~p"/"} class="text-[15px] font-semibold tracking-tight text-base-content">
          BurpeeTrainer
        </.link>

        <%= if @current_user do %>
          <nav class="flex-1 flex items-center gap-0 text-sm">
            <.nav_link href={~p"/plans"}>Plans</.nav_link>
            <.nav_link href={~p"/log"}>Log</.nav_link>
            <.nav_link href={~p"/history"}>History</.nav_link>
            <.nav_link href={~p"/goals"}>Goals</.nav_link>
          </nav>

          <div class="flex items-center gap-3">
            <%= if @current_user do %>
              <span class="hidden sm:inline text-xs text-base-content/40">
                Hi, {@current_user.username}
              </span>
            <% end %>
            <%= if @current_level do %>
              <span class="hidden sm:inline-flex items-center rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary">
                {level_label(@current_level)}
              </span>
            <% end %>
            <.form for={%{}} action={~p"/logout"} method="delete" class="inline">
              <button
                type="submit"
                class="text-xs px-3 py-1.5 rounded-md border border-[#1E2535] text-base-content/50 hover:text-base-content hover:border-base-content/20 transition-colors"
              >
                Out
              </button>
            </.form>
          </div>
        <% else %>
          <div class="flex-1" />
        <% end %>
      </div>
    </header>

    <main class="mx-auto max-w-2xl px-4 py-8 sm:px-6">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  defp level_label(:graduated), do: "Grad"

  defp level_label(l),
    do: l |> Atom.to_string() |> String.replace("level_", "") |> String.upcase()

  attr :href, :string, required: true
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="px-3 py-[14px] text-sm text-base-content/50 hover:text-base-content transition-colors border-b-2 border-transparent [&.active]:border-primary [&.active]:text-base-content"
      data-active-class="active"
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
