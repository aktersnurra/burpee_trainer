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
  attr :current_page, :atom, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%= if @current_user do %>
      <%!-- Desktop top nav — hidden on mobile --%>
      <nav class="hidden sm:flex items-center justify-center gap-1 px-4 py-2 border-b border-[#141B26] bg-[#0D1017]">
        <.nav_icon navigate={~p"/"} title="Home" active={@current_page == :home}>
          <.icon name="hero-home-solid" class={if @current_page == :home, do: "", else: "hidden"} />
          <.icon name="hero-home" class={if @current_page == :home, do: "hidden", else: ""} />
        </.nav_icon>

        <.nav_icon navigate={~p"/plans"} title="Plans" active={@current_page == :plans}>
          <.icon
            name="hero-rectangle-stack-solid"
            class={if @current_page == :plans, do: "", else: "hidden"}
          />
          <.icon
            name="hero-rectangle-stack"
            class={if @current_page == :plans, do: "hidden", else: ""}
          />
        </.nav_icon>

        <.nav_icon navigate={~p"/log"} title="Log" active={@current_page == :log}>
          <.icon
            name="hero-pencil-square-solid"
            class={if @current_page == :log, do: "", else: "hidden"}
          />
          <.icon name="hero-pencil-square" class={if @current_page == :log, do: "hidden", else: ""} />
        </.nav_icon>

        <.nav_icon navigate={~p"/history"} title="History" active={@current_page == :history}>
          <.icon
            name="hero-chart-bar-solid"
            class={if @current_page == :history, do: "", else: "hidden"}
          />
          <.icon name="hero-chart-bar" class={if @current_page == :history, do: "hidden", else: ""} />
        </.nav_icon>

        <.nav_icon navigate={~p"/goals"} title="Goals" active={@current_page == :goals}>
          <.icon name="hero-flag-solid" class={if @current_page == :goals, do: "", else: "hidden"} />
          <.icon name="hero-flag" class={if @current_page == :goals, do: "hidden", else: ""} />
        </.nav_icon>

        <.nav_icon navigate={~p"/videos"} title="Videos" active={@current_page == :videos}>
          <.icon
            name="hero-play-circle-solid"
            class={if @current_page == :videos, do: "", else: "hidden"}
          />
          <.icon name="hero-play-circle" class={if @current_page == :videos, do: "hidden", else: ""} />
        </.nav_icon>

        <div class="w-px h-4 bg-[#141B26] mx-1" />

        <.link
          href={~p"/logout"}
          method="delete"
          title="Sign out"
          class="inline-flex items-center justify-center w-9 h-9 shrink-0 rounded transition-colors text-[#3A4A5E] hover:text-[#C8D8F0] hover:bg-[#141B26]"
        >
          <.icon name="hero-arrow-left-start-on-rectangle" />
        </.link>
      </nav>

      <%!-- Mobile bottom tab bar --%>
      <nav class="fixed bottom-0 inset-x-0 z-50 sm:hidden flex items-center justify-around bg-[#0D1017] border-t border-[#141B26] pb-safe">
        <.bottom_tab navigate={~p"/"} active={@current_page == :home}>
          <.icon name="hero-home-solid" class={if @current_page == :home, do: "", else: "hidden"} />
          <.icon name="hero-home" class={if @current_page == :home, do: "hidden", else: ""} />
        </.bottom_tab>

        <.bottom_tab navigate={~p"/plans"} active={@current_page == :plans}>
          <.icon
            name="hero-rectangle-stack-solid"
            class={if @current_page == :plans, do: "", else: "hidden"}
          />
          <.icon
            name="hero-rectangle-stack"
            class={if @current_page == :plans, do: "hidden", else: ""}
          />
        </.bottom_tab>

        <.bottom_tab navigate={~p"/log"} active={@current_page == :log}>
          <.icon
            name="hero-pencil-square-solid"
            class={if @current_page == :log, do: "", else: "hidden"}
          />
          <.icon name="hero-pencil-square" class={if @current_page == :log, do: "hidden", else: ""} />
        </.bottom_tab>

        <.bottom_tab navigate={~p"/history"} active={@current_page == :history}>
          <.icon
            name="hero-chart-bar-solid"
            class={if @current_page == :history, do: "", else: "hidden"}
          />
          <.icon name="hero-chart-bar" class={if @current_page == :history, do: "hidden", else: ""} />
        </.bottom_tab>

        <.bottom_tab navigate={~p"/goals"} active={@current_page == :goals}>
          <.icon name="hero-flag-solid" class={if @current_page == :goals, do: "", else: "hidden"} />
          <.icon name="hero-flag" class={if @current_page == :goals, do: "hidden", else: ""} />
        </.bottom_tab>

        <.bottom_tab navigate={~p"/videos"} active={@current_page == :videos}>
          <.icon
            name="hero-play-circle-solid"
            class={if @current_page == :videos, do: "", else: "hidden"}
          />
          <.icon name="hero-play-circle" class={if @current_page == :videos, do: "hidden", else: ""} />
        </.bottom_tab>

        <.link
          href={~p"/logout"}
          method="delete"
          title="Sign out"
          class="inline-flex items-center justify-center w-14 h-14 shrink-0 transition-colors text-[#3A4A5E] hover:text-[#C8D8F0]"
        >
          <.icon name="hero-arrow-left-start-on-rectangle" />
        </.link>
      </nav>
    <% end %>

    <main class="mx-auto max-w-2xl px-4 py-8 sm:px-6">
      {render_slot(@inner_block)}
    </main>

    <%= if @current_user do %>
      <div class="sm:hidden h-16" />
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :title, :string, required: true
  attr :active, :boolean, required: true
  slot :inner_block, required: true

  defp nav_icon(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      title={@title}
      class={[
        "inline-flex items-center justify-center w-9 h-9 shrink-0 rounded transition-colors",
        @active && "text-[#C8D8F0] bg-[#141B26]",
        !@active && "text-[#3A4A5E] hover:text-[#6B8FA8] hover:bg-[#141B26]"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :navigate, :string, required: true
  attr :active, :boolean, required: true
  slot :inner_block, required: true

  defp bottom_tab(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "inline-flex items-center justify-center w-14 h-14 shrink-0 transition-colors",
        @active && "text-[#4A9EFF]",
        !@active && "text-[#3A4A5E]"
      ]}
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
