defmodule BurpeeTrainerWeb.WorkoutsLive do
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Levels, Workouts}
  alias BurpeeTrainer.WorkoutFeed
  alias BurpeeTrainer.WorkoutFeed.WorkoutItem
  alias BurpeeTrainerWeb.{Fmt, Layouts}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, filters: %{}, items: [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = decode_filters(params)
    items = WorkoutFeed.list(socket.assigns.current_user, filters)
    {:noreply, assign(socket, filters: filters, items: items)}
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

  def handle_event("duplicate", %{"id" => id}, socket) do
    plan = Workouts.get_plan!(socket.assigns.current_user, String.to_integer(id))

    case Workouts.duplicate_plan(plan) do
      {:ok, _copy} ->
        items = WorkoutFeed.list(socket.assigns.current_user, socket.assigns.filters)
        {:noreply, socket |> put_flash(:info, "Plan duplicated.") |> assign(:items, items)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not duplicate plan.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    plan = Workouts.get_plan!(socket.assigns.current_user, String.to_integer(id))

    case Workouts.delete_plan(plan) do
      {:ok, _} ->
        items = WorkoutFeed.list(socket.assigns.current_user, socket.assigns.filters)
        {:noreply, socket |> put_flash(:info, "Plan deleted.") |> assign(:items, items)}

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

  # Level pill labels in display order (highest to lowest)
  @level_pills [
    {:graduated, "Grad"},
    {:level_4, "L4"},
    {:level_3, "L3"},
    {:level_2, "L2"},
    {:level_1d, "1D"},
    {:level_1c, "1C"},
    {:level_1b, "1B"},
    {:level_1a, "1A"}
  ]

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :level_pills, @level_pills)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:workouts}>
      <div class="space-y-4">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Workouts</h1>
          <p class="text-sm text-base-content/60">Pick something to do.</p>
        </div>

        <%!-- Source filter row --%>
        <div class="flex gap-2">
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
        </div>

        <%!-- Type + level filter row (scrollable on small screens) --%>
        <div class="flex gap-2 overflow-x-auto pb-0.5 no-scrollbar">
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
          <div class="w-px h-5 bg-[#1E2535] self-center shrink-0 mx-0.5" />
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
          <div class="space-y-2">
            <%= for item <- @items do %>
              <.workout_card item={item} />
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- FAB — subtle, smaller --%>
      <div class="fixed bottom-20 right-4 sm:bottom-8 sm:right-6 z-40">
        <.link
          navigate={~p"/workouts/new"}
          class="w-10 h-10 rounded-full bg-[#141B26] border border-[#1E2535] text-[#4A9EFF] flex items-center justify-center hover:bg-[#1E2535] transition"
          aria-label="New plan"
        >
          <.icon name="hero-plus" class="size-5" />
        </.link>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value_key, :string, required: true
  attr :value, :string, required: true
  attr :active, :boolean, required: true

  defp filter_pill(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_filter"
      phx-value-source={if @value_key == "source", do: @value}
      phx-value-burpee_type={if @value_key == "burpee_type", do: @value}
      phx-value-level={if @value_key == "level", do: @value}
      class={[
        "rounded-full px-3 py-1 text-xs font-medium transition whitespace-nowrap shrink-0",
        @active && "bg-[#1E2535] text-base-content",
        !@active && "text-base-content/40 hover:text-base-content/70"
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :item, WorkoutItem, required: true

  defp workout_card(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 px-4 py-3">
      <div class="flex items-start justify-between gap-3">
        <%!-- Left: content --%>
        <div class="min-w-0 space-y-1">
          <p class="font-semibold text-sm leading-snug truncate">{@item.title}</p>
          <p class="text-xs text-base-content/50 tabular-nums">
            <%= if @item.burpee_count do %>
              {@item.burpee_count} burpees · {Fmt.duration_sec(@item.duration_sec)}
            <% else %>
              {Fmt.duration_sec(@item.duration_sec)}
            <% end %>
            <%= if @item.level do %>
              · {Fmt.level(@item.level)}
            <% end %>
          </p>
          <p class="text-xs text-base-content/30">{Fmt.burpee_type(@item.burpee_type)}</p>
        </div>

        <%!-- Right: actions --%>
        <div class="flex items-center gap-1 shrink-0">
          <%= if @item.kind == :plan && @item.edit_path do %>
            <.link
              navigate={@item.edit_path}
              class="p-1.5 text-base-content/30 hover:text-base-content/70 transition rounded"
              title="Edit / more"
            >
              <.icon name="hero-ellipsis-horizontal" class="size-4" />
            </.link>
          <% end %>
          <.link
            navigate={@item.start_path}
            class="p-1.5 text-[#4A9EFF] hover:text-[#4A9EFF]/80 transition rounded"
            aria-label={"Start #{@item.title}"}
          >
            <.icon name="hero-play-circle" class="size-6" />
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr :filters, :map, required: true

  defp empty_state(%{filters: %{source: :mine}} = assigns) do
    ~H"""
    <div class="rounded-lg border border-dashed border-base-300 p-12 text-center space-y-3">
      <p class="text-base-content/70">You have not built any plans yet.</p>
      <.link
        navigate={~p"/workouts/new"}
        class="inline-flex items-center gap-1 text-sm text-primary hover:underline"
      >
        <.icon name="hero-plus" class="size-4" /> New plan
      </.link>
    </div>
    """
  end

  defp empty_state(%{filters: filters} = assigns) when map_size(filters) > 0 do
    ~H"""
    <div class="rounded-lg border border-dashed border-base-300 p-12 text-center space-y-3">
      <p class="text-base-content/70">Nothing matches these filters.</p>
      <.link patch="/workouts" class="text-sm text-primary hover:underline">Clear filters</.link>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="rounded-lg border border-dashed border-base-300 p-12 text-center space-y-2">
      <p class="text-base-content/70">No workouts yet.</p>
      <p class="text-sm text-base-content/50">Tap + to build your first plan.</p>
    </div>
    """
  end
end
