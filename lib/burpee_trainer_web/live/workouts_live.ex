defmodule BurpeeTrainerWeb.WorkoutsLive do
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Levels, WeeklyTrainingContract, Workouts}
  alias BurpeeTrainer.WorkoutFeed
  alias BurpeeTrainer.WorkoutFeed.WorkoutItem
  alias BurpeeTrainerWeb.{Fmt, Layouts}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, filters: %{}, items: [], open_menu_id: nil, available_levels: [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = decode_filters(params)
    # Load without level filter to compute which levels actually exist
    items_unfiltered = WorkoutFeed.list(socket.assigns.current_user, Map.delete(filters, :level))

    available_levels =
      items_unfiltered |> Enum.map(& &1.level) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    items =
      if Map.has_key?(filters, :level) do
        Enum.filter(items_unfiltered, &(&1.level == filters.level))
      else
        items_unfiltered
      end

    weekly_status =
      socket.assigns.current_user
      |> Workouts.list_sessions()
      |> WeeklyTrainingContract.status(Date.utc_today() |> Date.beginning_of_week(:monday))

    {:noreply,
     assign(socket,
       filters: filters,
       items: items,
       available_levels: available_levels,
       weekly_complete?: weekly_status.remaining_min <= 0
     )}
  end

  @impl true
  def handle_event("toggle_filter", %{"source" => val}, socket) do
    filters = toggle_filter(socket.assigns.filters, :source, String.to_existing_atom(val))
    {:noreply, push_patch(socket, to: build_path(filters))}
  end

  def handle_event("toggle_filter", %{"burpee_type" => val}, socket) do
    filters = toggle_filter(socket.assigns.filters, :burpee_type, String.to_existing_atom(val))
    {:noreply, push_patch(socket, to: build_path(filters))}
  end

  def handle_event("toggle_filter", %{"level" => val}, socket) do
    filters = toggle_filter(socket.assigns.filters, :level, String.to_existing_atom(val))
    {:noreply, push_patch(socket, to: build_path(filters))}
  end

  def handle_event("toggle_menu", %{"id" => id}, socket) do
    open = if socket.assigns.open_menu_id == id, do: nil, else: id
    {:noreply, assign(socket, :open_menu_id, open)}
  end

  def handle_event("close_menu", _, socket) do
    {:noreply, assign(socket, :open_menu_id, nil)}
  end

  def handle_event("duplicate", %{"id" => id}, socket) do
    plan = Workouts.get_plan!(socket.assigns.current_user, String.to_integer(id))

    case Workouts.duplicate_plan(plan) do
      {:ok, _copy} ->
        items = WorkoutFeed.list(socket.assigns.current_user, socket.assigns.filters)

        {:noreply,
         socket
         |> put_flash(:info, "Plan duplicated.")
         |> assign(:items, items)
         |> assign(:open_menu_id, nil)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not duplicate plan.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    plan = Workouts.get_plan!(socket.assigns.current_user, String.to_integer(id))

    case Workouts.delete_plan(plan) do
      {:ok, _} ->
        items = WorkoutFeed.list(socket.assigns.current_user, socket.assigns.filters)

        {:noreply,
         socket
         |> put_flash(:info, "Plan deleted.")
         |> assign(:items, items)
         |> assign(:open_menu_id, nil)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete plan.")}
    end
  end

  defp toggle_filter(filters, key, value) do
    if Map.get(filters, key) == value,
      do: Map.delete(filters, key),
      else: Map.put(filters, key, value)
  end

  defp decode_filters(params) do
    %{}
    |> maybe_put(:source, params["source"], ~w(mine videos))
    |> maybe_put(:burpee_type, params["burpee_type"], ~w(six_count navy_seal))
    |> maybe_put(:level, params["level"], Enum.map(Levels.all_levels(), &Atom.to_string/1))
  end

  defp maybe_put(map, _key, nil, _valid), do: map

  defp maybe_put(map, key, val, valid) do
    if val in valid, do: Map.put(map, key, String.to_existing_atom(val)), else: map
  end

  defp build_path(filters) do
    params =
      filters
      |> Enum.map(fn {k, v} -> {Atom.to_string(k), Atom.to_string(v)} end)
      |> Map.new()

    if params == %{}, do: "/workouts", else: "/workouts?" <> URI.encode_query(params)
  end

  # Ordered ascending for filter pills (1A first, Grad last)
  @level_order [
    :level_1a,
    :level_1b,
    :level_1c,
    :level_1d,
    :level_2,
    :level_3,
    :level_4,
    :graduated
  ]
  @level_labels %{
    graduated: "Grad",
    level_4: "4",
    level_3: "3",
    level_2: "2",
    level_1d: "1D",
    level_1c: "1C",
    level_1b: "1B",
    level_1a: "1A"
  }

  @impl true
  def render(assigns) do
    level_pills =
      @level_order
      |> Enum.filter(&(&1 in assigns.available_levels))
      |> Enum.map(&{&1, @level_labels[&1]})

    featured_item = if assigns.weekly_complete?, do: nil, else: List.first(assigns.items)
    filter_count = map_size(assigns.filters)

    assigns =
      assigns
      |> assign(:level_pills, level_pills)
      |> assign(:featured_item, featured_item)
      |> assign(:filter_count, filter_count)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:workouts}>
      <div
        id="workouts-page"
        class="session-surface mx-auto max-w-lg space-y-8 pb-24 text-[var(--session-ink)]"
      >
        <header class="space-y-1 px-1">
          <p class="text-sm font-medium text-[var(--session-muted)]">Workouts</p>
          <h1 class="text-3xl font-semibold leading-none tracking-[-0.05em] text-[var(--session-ink)]">
            Choose training
          </h1>
          <p class="text-sm leading-6 text-[var(--session-muted)]">
            Pick the next session, edit a plan, or start from a video.
          </p>
        </header>

        <.featured_workout :if={@featured_item} item={@featured_item} />

        <.qs_surface
          id="workouts-primary-actions"
          class="overflow-hidden bg-[var(--session-surface)]/45"
        >
          <.qs_action_row
            id="workouts-new-workout"
            navigate={~p"/workouts/new"}
            icon="hero-plus"
            label="New workout"
            description="Build a custom session prescription"
          />
        </.qs_surface>

        <section id="workouts-options-section" class="space-y-4 pt-1">
          <details id="workouts-filter-panel" class="group" open={@filter_count > 0}>
            <summary
              class="flex size-9 cursor-pointer list-none items-center justify-center text-[var(--session-muted)] transition hover:text-[var(--session-ink)] marker:hidden"
              aria-label="Filter workouts"
            >
              <span class="sr-only">Filters</span>
              <span class="relative">
                <.icon name="hero-funnel" class="size-5" />
                <span
                  :if={@filter_count > 0}
                  class="absolute -right-1.5 -top-1.5 flex size-4 items-center justify-center rounded-full bg-[var(--session-progress)] text-[9px] font-semibold leading-none text-white"
                >
                  {@filter_count}
                </span>
              </span>
            </summary>
            <div class="mt-3 space-y-3 bg-[var(--session-bg)] px-1 py-3">
              <div class="flex items-center justify-between gap-4">
                <p class="text-sm font-semibold text-[var(--session-ink)]">Filters</p>
                <.link
                  :if={@filter_count > 0}
                  patch={~p"/workouts"}
                  class="text-xs font-medium text-[var(--session-muted)] transition hover:text-[var(--session-ink)]"
                >
                  Clear
                </.link>
              </div>
              <.filter_group label="Source">
                <.filter_pill
                  label="Saved plans"
                  value_key="source"
                  value="mine"
                  active={@filters[:source] == :mine}
                />
                <.filter_pill
                  label="Videos"
                  value_key="source"
                  value="videos"
                  active={@filters[:source] == :videos}
                />
              </.filter_group>

              <.filter_group label="Style">
                <.filter_pill
                  label="6-count"
                  value_key="burpee_type"
                  value="six_count"
                  active={@filters[:burpee_type] == :six_count}
                />
                <.filter_pill
                  label="Navy SEAL"
                  value_key="burpee_type"
                  value="navy_seal"
                  active={@filters[:burpee_type] == :navy_seal}
                />
              </.filter_group>

              <.filter_group :if={@level_pills != []} label="Level">
                <%= for {level_atom, label} <- @level_pills do %>
                  <.filter_pill
                    label={label}
                    value_key="level"
                    value={Atom.to_string(level_atom)}
                    active={@filters[:level] == level_atom}
                  />
                <% end %>
              </.filter_group>
            </div>
          </details>

          <%!-- List or empty state --%>
          <%= if @items == [] do %>
            <.empty_state filters={@filters} />
          <% else %>
            <div id="workouts-list" class="space-y-3">
              <%= for item <- @items do %>
                <.workout_card
                  item={item}
                  open_menu={@open_menu_id == to_string(item.id) <> to_string(item.kind)}
                />
              <% end %>
            </div>
          <% end %>
        </section>

        <.qs_surface id="workouts-utilities" class="overflow-hidden bg-[var(--session-surface)]/35">
          <.qs_action_row
            id="workouts-camera-debug"
            navigate={~p"/tracking-test"}
            icon="hero-camera"
            label="Camera debug"
            description="Calibrate and inspect pose tracking"
          />
        </.qs_surface>
      </div>
    </Layouts.app>
    """
  end

  attr(:item, WorkoutItem, default: nil)

  defp featured_workout(%{item: nil} = assigns) do
    ~H"""
    <.qs_surface id="workouts-featured-card" class="bg-[var(--session-surface)]/60">
      <div class="space-y-2 px-5 py-5">
        <p class="text-sm font-medium text-[var(--session-muted)]">Ready when you are</p>
        <p class="qs-section-tight text-xl font-semibold tracking-[-0.03em] text-[var(--session-ink)]">
          Build a plan to start training
        </p>
      </div>
      <.qs_action_row
        navigate={~p"/workouts/new"}
        icon="hero-plus"
        label="New plan"
        class="border-t border-[var(--session-border)]"
      />
    </.qs_surface>
    """
  end

  defp featured_workout(assigns) do
    ~H"""
    <.qs_surface id="workouts-featured-card" class="bg-[var(--session-surface)]/60">
      <div class="flex items-start gap-5 px-5 py-5">
        <div class="flex size-24 shrink-0 flex-col items-center justify-center rounded-lg border border-[var(--session-border)] bg-[var(--session-bg)]/55 text-center">
          <%= if @item.burpee_count do %>
            <span class="text-4xl font-semibold leading-none tracking-[-0.05em] tabular-nums text-[var(--session-ink)]">
              {@item.burpee_count}
            </span>
            <span class="mt-1 text-xs font-medium text-[var(--session-muted)]">
              reps
            </span>
          <% else %>
            <span class="text-2xl font-semibold leading-none tracking-[-0.04em] tabular-nums text-[var(--session-ink)]">
              {Fmt.duration_sec(@item.duration_sec)}
            </span>
          <% end %>
        </div>
        <div class="min-w-0 flex-1 space-y-3">
          <div class="flex flex-wrap items-center gap-1.5">
            <.qs_property_tag tone="tag">Featured</.qs_property_tag>
            <.qs_property_tag tone="info">{Fmt.burpee_type(@item.burpee_type)}</.qs_property_tag>
            <.qs_property_tag :if={@item.level}>{Fmt.level(@item.level)}</.qs_property_tag>
          </div>
          <div>
            <p class="text-sm font-medium text-[var(--session-muted)]">Ready when you are</p>
            <h2 class="qs-section-tight mt-1 truncate text-2xl font-semibold tracking-[-0.04em] text-[var(--session-ink)]">
              {@item.title}
            </h2>
          </div>
        </div>
      </div>
      <div class="flex items-center justify-between gap-3 border-t border-[var(--session-border)] px-5 py-4">
        <.link
          navigate={if @item.kind == :plan, do: @item.edit_path, else: @item.start_path}
          class="rounded-md border border-[var(--session-border)] bg-[var(--session-bg)]/55 px-3 py-2 text-sm font-medium text-[var(--session-ink)] transition hover:bg-[var(--session-track)]/70"
        >
          {if @item.kind == :plan, do: "Edit", else: "View"}
        </.link>
        <.link
          navigate={@item.start_path}
          class="inline-flex items-center gap-2 rounded-md bg-[var(--session-ink)] px-4 py-2 text-sm font-medium text-[var(--session-bg)] transition hover:opacity-90"
          aria-label={"Start #{@item.title}"}
        >
          <.icon name="hero-play-solid" class="size-4" /> Run
        </.link>
      </div>
    </.qs_surface>
    """
  end

  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  defp filter_group(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <p class="px-1 text-xs font-medium text-[var(--session-muted)]">{@label}</p>
      <div class="flex gap-2 overflow-x-auto no-scrollbar">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value_key, :string, required: true)
  attr(:value, :string, required: true)
  attr(:active, :boolean, required: true)

  defp filter_pill(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_filter"
      phx-value-source={if @value_key == "source", do: @value}
      phx-value-burpee_type={if @value_key == "burpee_type", do: @value}
      phx-value-level={if @value_key == "level", do: @value}
      class={[
        "border px-3 py-1.5 text-sm font-medium transition-colors whitespace-nowrap",
        @active && @value_key == "source" &&
          "border-[var(--session-info-border)] bg-[var(--session-info-bg)] text-[var(--session-info-ink)]",
        @active && @value_key != "source" &&
          "border-[var(--session-toggle-border)] bg-[var(--session-toggle-bg)] text-[var(--session-toggle-ink)]",
        !@active &&
          "border-[var(--session-border)] bg-[var(--session-surface)]/45 text-[var(--session-muted)] hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
      ]}
    >
      {@label}
    </button>
    """
  end

  attr(:item, WorkoutItem, required: true)
  attr(:open_menu, :boolean, required: true)

  defp workout_card(assigns) do
    menu_id = to_string(assigns.item.id) <> to_string(assigns.item.kind)
    assigns = assign(assigns, :menu_id, menu_id)

    ~H"""
    <.qs_surface data-workout-row class="bg-[var(--session-surface)]/55 px-5 py-5">
      <div class="flex items-start justify-between gap-5">
        <div class="min-w-0 flex-1 space-y-3">
          <div class="space-y-1">
            <p class="qs-section-tight truncate text-xl font-semibold leading-tight tracking-[-0.03em] text-[var(--session-ink)]">
              {@item.title}
            </p>
            <p class="text-sm font-medium text-[var(--session-muted)] tabular-nums">
              <%= if @item.burpee_count do %>
                {@item.burpee_count} reps · {Fmt.duration_sec(@item.duration_sec)}
              <% else %>
                {Fmt.duration_sec(@item.duration_sec)}
              <% end %>
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-1.5">
            <.qs_property_tag :if={@item.kind == :video} tone="tag">Video</.qs_property_tag>
            <.qs_property_tag tone="info">{Fmt.burpee_type(@item.burpee_type)}</.qs_property_tag>
            <.qs_property_tag :if={@item.level}>{Fmt.level(@item.level)}</.qs_property_tag>
          </div>
        </div>

        <div class="shrink-0 text-right tabular-nums">
          <%= if @item.burpee_count do %>
            <p class="text-3xl font-semibold leading-none tracking-[-0.05em] text-[var(--session-ink)]">
              {@item.burpee_count}
            </p>
            <p class="mt-1 text-xs font-medium text-[var(--session-muted)]">reps</p>
          <% else %>
            <p class="text-xl font-semibold leading-none tracking-[-0.03em] text-[var(--session-ink)]">
              {Fmt.duration_sec(@item.duration_sec)}
            </p>
          <% end %>
        </div>
      </div>

      <div class="mt-5 flex items-center gap-2 border-t border-[var(--session-border)] pt-4">
        <.link
          id={"workout-card-#{@item.kind}-#{@item.id}"}
          navigate={if @item.kind == :plan, do: @item.edit_path, else: @item.start_path}
          class="flex flex-1 items-center justify-center rounded-md border border-[var(--session-border)] bg-[var(--session-bg)]/55 px-3 py-2.5 text-sm font-medium text-[var(--session-ink)] transition hover:bg-[var(--session-track)]/70"
        >
          {if @item.kind == :plan, do: "Edit", else: "View"}
        </.link>
        <.link
          id={"workout-play-#{@item.kind}-#{@item.id}"}
          navigate={@item.start_path}
          class="flex flex-1 items-center justify-center gap-2 rounded-md bg-[var(--session-ink)] px-3 py-2.5 text-sm font-medium text-[var(--session-bg)] transition hover:opacity-90"
          aria-label={"Start #{@item.title}"}
        >
          <.icon name="hero-play-solid" class="size-4" /> Run
        </.link>
      </div>
    </.qs_surface>
    """
  end

  attr(:filters, :map, required: true)

  defp empty_state(%{filters: %{source: :mine}} = assigns) do
    ~H"""
    <.qs_surface class="bg-[var(--session-surface)]/45 px-6 py-14 text-center">
      <p class="text-base font-semibold text-[var(--session-ink)]">
        No plans yet
      </p>
      <p class="mt-3 text-sm text-[var(--session-muted)]">
        You have not built any plans yet. Build a session prescription to run later.
      </p>
      <.link
        navigate={~p"/workouts/new"}
        class="mt-6 inline-flex items-center rounded-md border border-[var(--session-border)] bg-[var(--session-surface)]/55 px-4 py-3 text-sm font-medium text-[var(--session-ink)] transition hover:bg-[var(--session-track)]/70"
      >
        New workout
      </.link>
    </.qs_surface>
    """
  end

  defp empty_state(%{filters: filters} = assigns) when map_size(filters) > 0 do
    ~H"""
    <.qs_surface class="bg-[var(--session-surface)]/45 px-6 py-14 text-center">
      <p class="text-base font-semibold text-[var(--session-ink)]">
        No matching sessions
      </p>
      <.link
        patch="/workouts"
        class="mt-5 inline-flex text-sm font-medium text-[var(--session-ink)] transition hover:text-[var(--session-muted)]"
      >
        Clear filters
      </.link>
    </.qs_surface>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <.qs_surface class="bg-[var(--session-surface)]/45 px-6 py-14 text-center">
      <p class="text-base font-semibold text-[var(--session-ink)]">
        No workouts yet
      </p>
      <p class="mt-3 text-sm text-[var(--session-muted)]">Tap + to build your first plan.</p>
    </.qs_surface>
    """
  end
end
