defmodule BurpeeTrainerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use BurpeeTrainerWeb, :html

  embed_templates("layouts/*")

  @doc """
  Main app layout. `current_user` is optional — the login page passes
  `nil` and the navigation adapts accordingly.
  """
  attr(:flash, :map, required: true)
  attr(:current_user, :any, default: nil)
  attr(:current_level, :atom, default: nil)
  attr(:current_page, :atom, default: nil)
  slot(:inner_block, required: true)

  def app(assigns) do
    assigns =
      Map.put(assigns, :session_surface_page?, session_surface_page?(assigns.current_page))

    ~H"""
    <%= if @current_user do %>
      <%!-- Desktop top nav — hidden on mobile --%>
      <nav class={[
        "hidden sm:flex items-center justify-center gap-2 px-4 py-3 border-b",
        @session_surface_page? &&
          "session-surface border-[var(--session-border)] bg-[var(--session-bg)]/95 text-[var(--session-ink)]",
        !@session_surface_page? && "border-base-border bg-base-nav text-base-content"
      ]}>
        <.nav_icon
          navigate={~p"/"}
          title="Home"
          active={@current_page == :home}
          session_nav?={@session_surface_page?}
        >
          <.icon name="hero-home-solid" class={if @current_page == :home, do: "", else: "hidden"} />
          <.icon name="hero-home" class={if @current_page == :home, do: "hidden", else: ""} />
        </.nav_icon>

        <.nav_icon
          navigate={~p"/workouts"}
          title="Workouts"
          active={@current_page == :workouts}
          session_nav?={@session_surface_page?}
        >
          <.icon
            name="hero-rectangle-stack-solid"
            class={if @current_page == :workouts, do: "", else: "hidden"}
          />
          <.icon
            name="hero-rectangle-stack"
            class={if @current_page == :workouts, do: "hidden", else: ""}
          />
        </.nav_icon>

        <.nav_icon
          navigate={~p"/stats"}
          title="Stats"
          active={@current_page == :stats}
          session_nav?={@session_surface_page?}
        >
          <.icon
            name="hero-chart-bar-solid"
            class={if @current_page == :stats, do: "", else: "hidden"}
          />
          <.icon name="hero-chart-bar" class={if @current_page == :stats, do: "hidden", else: ""} />
        </.nav_icon>
      </nav>

      <%!-- Mobile bottom tab bar --%>
      <nav class={[
        "fixed bottom-0 inset-x-0 z-50 sm:hidden flex justify-around border-t pb-safe backdrop-blur",
        @session_surface_page? &&
          "session-surface h-[84px] items-start border-[var(--session-border)] bg-[var(--session-bg)]/95",
        !@session_surface_page? && "h-16 border-base-border bg-base-nav/95"
      ]}>
        <.bottom_tab
          navigate={~p"/"}
          active={@current_page == :home}
          label="Home"
          session_nav?={@session_surface_page?}
        >
          <.icon name="hero-home-solid" class={if @current_page == :home, do: "", else: "hidden"} />
          <.icon name="hero-home" class={if @current_page == :home, do: "hidden", else: ""} />
        </.bottom_tab>

        <.bottom_tab
          navigate={~p"/workouts"}
          active={@current_page == :workouts}
          label="Workouts"
          session_nav?={@session_surface_page?}
        >
          <.icon
            name="hero-rectangle-stack-solid"
            class={if @current_page == :workouts, do: "", else: "hidden"}
          />
          <.icon
            name="hero-rectangle-stack"
            class={if @current_page == :workouts, do: "hidden", else: ""}
          />
        </.bottom_tab>

        <.bottom_tab
          navigate={~p"/stats"}
          active={@current_page == :stats}
          label="Stats"
          session_nav?={@session_surface_page?}
        >
          <.icon
            name="hero-chart-bar-solid"
            class={if @current_page == :stats, do: "", else: "hidden"}
          />
          <.icon name="hero-chart-bar" class={if @current_page == :stats, do: "hidden", else: ""} />
        </.bottom_tab>
      </nav>
    <% end %>

    <main class={[
      "px-4 pb-8 pt-[max(2rem,env(safe-area-inset-top))] sm:px-6",
      @session_surface_page? &&
        "session-surface min-h-dvh bg-[var(--session-bg)] text-[var(--session-ink)]",
      !@session_surface_page? && "mx-auto max-w-2xl"
    ]}>
      {render_slot(@inner_block)}
    </main>

    <%= if @current_user do %>
      <div class={[
        "sm:hidden",
        @session_surface_page? &&
          "session-surface h-[84px] bg-[var(--session-bg)]",
        !@session_surface_page? && "h-16"
      ]} />
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  defp session_surface_page?(:home), do: true
  defp session_surface_page?(:workouts), do: true
  defp session_surface_page?(:stats), do: true
  defp session_surface_page?(:plans), do: true
  defp session_surface_page?(:tracking_test), do: true
  defp session_surface_page?(_page), do: false

  attr(:id, :string, default: "theme-toggle")
  attr(:session_nav?, :boolean, default: false)
  attr(:label, :boolean, default: false)
  attr(:class, :any, default: nil)

  def theme_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={JS.dispatch("phx:toggle-theme")}
      class={[
        "items-center justify-center gap-2 rounded-xl border transition",
        @label && "px-3 py-2 text-sm font-medium",
        !@label && "size-9",
        @session_nav? &&
          "session-surface border-[var(--session-border)] text-[var(--session-muted)] hover:text-[var(--session-ink)] hover:bg-[var(--session-surface-alt)]",
        !@session_nav? &&
          "border-base-border text-base-muted hover:text-base-content hover:bg-base-raised",
        @class
      ]}
      aria-label="Toggle color theme"
    >
      <.icon name="hero-moon" class="size-4 dark:hidden" />
      <.icon name="hero-sun" class="hidden size-4 dark:block" />
      <span :if={@label}>Theme</span>
    </button>
    """
  end

  attr(:navigate, :string, required: true)
  attr(:title, :string, required: true)
  attr(:active, :boolean, required: true)
  attr(:session_nav?, :boolean, default: false)
  slot(:inner_block, required: true)

  defp nav_icon(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      title={@title}
      class={[
        "relative inline-flex items-center justify-center w-10 h-10 rounded-xl transition-colors",
        @session_nav? && @active && "text-[var(--session-ink)]",
        @session_nav? && !@active &&
          "text-[var(--session-muted)] hover:text-[var(--session-ink)] hover:bg-[var(--session-surface-alt)]/60",
        !@session_nav? && @active && "text-base-content bg-base-raised",
        !@session_nav? && !@active &&
          "text-base-muted hover:text-base-content hover:bg-base-raised"
      ]}
    >
      <span
        :if={@session_nav? && @active}
        class="absolute left-1/2 top-[-13px] h-0.5 w-7 -translate-x-1/2 rounded-full bg-[var(--session-accent)]"
        aria-hidden="true"
      />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr(:navigate, :string, required: true)
  attr(:active, :boolean, required: true)
  attr(:label, :string, required: true)
  attr(:session_nav?, :boolean, default: false)
  slot(:inner_block, required: true)

  defp bottom_tab(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "relative inline-flex flex-col items-center transition-colors",
        @session_nav? && "h-[84px] min-w-0 flex-1 justify-start gap-1.5 pt-5",
        !@session_nav? && "h-14 w-16 shrink-0 justify-center gap-0.5",
        @session_nav? && @active && "font-medium text-[var(--session-ink)]",
        @session_nav? && !@active && "font-medium text-[var(--session-muted)]",
        !@session_nav? && @active && "text-base-content",
        !@session_nav? && !@active && "text-base-muted"
      ]}
    >
      <span
        :if={@session_nav? && @active}
        class="absolute left-1/2 top-0 h-0.5 w-7 -translate-x-1/2 rounded-full bg-[var(--session-accent)]"
        aria-hidden="true"
      />
      <span class={[@session_nav? && "[&_svg]:size-6", !@session_nav? && ""]}>
        {render_slot(@inner_block)}
      </span>
      <span class={[@session_nav? && "text-xs", !@session_nav? && "text-[10px] font-medium"]}>
        {@label}
      </span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr(:flash, :map, required: true)
  attr(:id, :string, default: "flash-group")

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
