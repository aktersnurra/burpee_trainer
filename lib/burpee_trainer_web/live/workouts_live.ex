defmodule BurpeeTrainerWeb.WorkoutsLive do
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Levels, Workouts}
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

    {:noreply, assign(socket, filters: filters, items: items, available_levels: available_levels)}
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

    assigns = assign(assigns, :level_pills, level_pills)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:workouts}>
      <div class="session-surface mx-auto max-w-lg space-y-6 bg-[var(--session-bg)] text-[var(--session-ink)]">
        <header class="space-y-2 px-1 pt-1">
          <p class="text-[10px] font-semibold uppercase tracking-[0.28em] text-[var(--session-soft-muted)]">
            Training menu
          </p>
          <div class="flex items-end justify-between gap-4">
            <h1 class="text-4xl font-black leading-none tracking-[-0.06em] text-[var(--session-ink)]">
              Choose session
            </h1>
            <.link
              navigate={~p"/tracking-test"}
              class="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[var(--session-muted)] transition hover:text-[var(--session-ink)]"
            >
              <span class="sr-only">Tracking Test</span>
              <span aria-hidden="true">Diagnostics</span>
            </.link>
          </div>
        </header>

        <%!-- Single scrollable filter row --%>
        <div class="flex gap-2 overflow-x-auto border-y border-[var(--session-border)] px-1 py-3 no-scrollbar">
          <.filter_pill
            label="Mine"
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
          <.filter_pill
            label="6-Count"
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
          <%= for {level_atom, label} <- @level_pills do %>
            <.filter_pill
              label={label}
              value_key="level"
              value={Atom.to_string(level_atom)}
              active={@filters[:level] == level_atom}
            />
          <% end %>
        </div>

        <%!-- List or empty state --%>
        <%= if @items == [] do %>
          <.empty_state filters={@filters} />
        <% else %>
          <div class="divide-y divide-[var(--session-border)] border-y border-[var(--session-border)]">
            <%= for item <- @items do %>
              <.workout_card
                item={item}
                open_menu={@open_menu_id == to_string(item.id) <> to_string(item.kind)}
              />
            <% end %>
          </div>
        <% end %>
      </div>

      <div class="session-surface fixed bottom-20 right-4 z-40 sm:bottom-8 sm:right-6">
        <.link
          navigate={~p"/workouts/new"}
          class="flex size-12 items-center justify-center border border-[var(--session-ink)] rounded-2xl bg-[var(--session-ink)] text-[var(--session-bg)] shadow-lg shadow-black/20 transition active:scale-95 hover:opacity-90"
          aria-label="New plan"
        >
          <.icon name="hero-plus" class="size-5" />
        </.link>
      </div>
    </Layouts.app>
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
        "shrink-0 border px-3 py-2 text-[10px] font-semibold uppercase tracking-[0.16em] transition whitespace-nowrap",
        @active && "border-[var(--session-ink)] bg-[var(--session-ink)] text-[var(--session-bg)]",
        !@active &&
          "border-transparent text-[var(--session-soft-muted)] hover:border-[var(--session-border)] hover:text-[var(--session-ink)]"
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
    <div class="relative">
      <div class="flex items-center gap-3 px-1 py-4 transition hover:bg-[var(--session-track)]/40">
        <.link
          id={"workout-card-#{@item.kind}-#{@item.id}"}
          navigate={if @item.kind == :plan, do: @item.edit_path, else: @item.start_path}
          class="group min-w-0 flex-1"
        >
          <div class="flex items-center justify-between gap-4">
            <div class="min-w-0 space-y-2">
              <div class="flex items-center gap-2">
                <p class="truncate text-lg font-bold leading-tight tracking-[-0.02em] text-[var(--session-ink)]">
                  {@item.title}
                </p>
                <%= if @item.kind == :video do %>
                  <span class="border border-[var(--session-border)] rounded-2xl px-1.5 py-0.5 text-[8px] font-semibold uppercase tracking-[0.16em] text-[var(--session-soft-muted)]">
                    Video
                  </span>
                <% end %>
              </div>
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-[10px] font-semibold uppercase tracking-[0.16em] text-[var(--session-soft-muted)]">
                <span>{Fmt.burpee_type(@item.burpee_type)}</span>
                <%= if @item.level do %>
                  <span>{Fmt.level(@item.level)}</span>
                <% end %>
              </div>
            </div>

            <div class="shrink-0 text-right tabular-nums">
              <%= if @item.burpee_count do %>
                <p class="text-3xl font-black leading-none tracking-[-0.05em] text-[var(--session-ink)]">
                  {@item.burpee_count}
                </p>
                <p class="mt-1 text-[9px] font-semibold uppercase tracking-[0.18em] text-[var(--session-soft-muted)]">
                  {Fmt.duration_sec(@item.duration_sec)}
                </p>
              <% else %>
                <p class="text-xl font-bold leading-none tracking-[-0.03em] text-[var(--session-ink)]">
                  {Fmt.duration_sec(@item.duration_sec)}
                </p>
              <% end %>
            </div>
          </div>
        </.link>

        <.link
          id={"workout-play-#{@item.kind}-#{@item.id}"}
          navigate={@item.start_path}
          class="flex size-10 shrink-0 items-center justify-center rounded-full border border-[var(--session-border)] text-[var(--session-muted)] transition hover:border-[var(--session-ink)] hover:text-[var(--session-ink)] active:scale-95"
          aria-label={"Start #{@item.title}"}
        >
          <.icon name="hero-chevron-right" class="size-4" />
        </.link>
      </div>
    </div>
    """
  end

  attr(:filters, :map, required: true)

  defp empty_state(%{filters: %{source: :mine}} = assigns) do
    ~H"""
    <div class="border-y border-[var(--session-border)] px-6 py-14 text-center">
      <p class="text-[10px] font-semibold uppercase tracking-[0.24em] text-[var(--session-soft-muted)]">
        No plans yet
      </p>
      <p class="mt-3 text-sm text-[var(--session-muted)]">
        You have not built any plans yet. Build a session prescription to run later.
      </p>
      <.link
        navigate={~p"/workouts/new"}
        class="mt-6 inline-flex items-center border border-[var(--session-ink)] rounded-2xl px-4 py-3 text-[10px] font-semibold uppercase tracking-[0.18em] text-[var(--session-ink)] transition hover:bg-[var(--session-ink)] hover:text-[var(--session-bg)]"
      >
        New plan
      </.link>
    </div>
    """
  end

  defp empty_state(%{filters: filters} = assigns) when map_size(filters) > 0 do
    ~H"""
    <div class="border-y border-[var(--session-border)] px-6 py-14 text-center">
      <p class="text-[10px] font-semibold uppercase tracking-[0.24em] text-[var(--session-soft-muted)]">
        No matching sessions
      </p>
      <.link
        patch="/workouts"
        class="mt-5 inline-flex text-[10px] font-semibold uppercase tracking-[0.18em] text-[var(--session-ink)] transition hover:text-[var(--session-muted)]"
      >
        Clear filters
      </.link>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="border-y border-[var(--session-border)] px-6 py-14 text-center">
      <p class="text-[10px] font-semibold uppercase tracking-[0.24em] text-[var(--session-soft-muted)]">
        No workouts yet
      </p>
      <p class="mt-3 text-sm text-[var(--session-muted)]">Tap + to build your first plan.</p>
    </div>
    """
  end
end
