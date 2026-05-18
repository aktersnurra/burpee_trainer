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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:workouts}>
      <div class="space-y-5">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Workouts</h1>
          <p class="text-sm text-base-content/60">Pick something to do.</p>
        </div>

        <%!-- Filter pill-bar --%>
        <div class="flex items-center bg-base-200 border border-base-300 rounded-full px-1.5 py-1 w-fit overflow-x-auto">
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
          <div class="w-px h-4 bg-base-300 mx-1.5 shrink-0" />
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
          <div class="w-px h-4 bg-base-300 mx-1.5 shrink-0" />
          <%!-- Level pills show the three milestone groups users progress through --%>
          <.filter_pill
            label="L1"
            value_key="level"
            value="level_1a"
            active={@filters[:level] == :level_1a}
          />
          <.filter_pill
            label="L2"
            value_key="level"
            value="level_2"
            active={@filters[:level] == :level_2}
          />
          <.filter_pill
            label="L3"
            value_key="level"
            value="level_3"
            active={@filters[:level] == :level_3}
          />
        </div>

        <%!-- List or empty state --%>
        <%= if @items == [] do %>
          <.empty_state filters={@filters} />
        <% else %>
          <div class="space-y-3">
            <%= for item <- @items do %>
              <.workout_card item={item} />
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- FAB --%>
      <div class="fixed bottom-20 right-4 sm:bottom-8 sm:right-8 z-40">
        <.link
          navigate={~p"/workouts/new"}
          class="w-12 h-12 rounded-full bg-primary text-primary-content shadow-lg flex items-center justify-center hover:bg-primary/90 transition"
          aria-label="New plan"
        >
          <.icon name="hero-plus" class="size-6" />
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
        "rounded-full px-3 py-1 text-xs font-medium transition whitespace-nowrap",
        @active && "bg-base-content text-base-100",
        !@active && "text-base-content/50 hover:text-base-content"
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :item, WorkoutItem, required: true

  defp workout_card(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-4 space-y-3">
      <div class="flex items-start justify-between gap-2">
        <span class="font-semibold text-base leading-snug">{@item.title}</span>
        <div class="flex gap-1.5 shrink-0 flex-wrap justify-end">
          <span class="inline-flex items-center rounded-full bg-base-300 px-2 py-0.5 text-xs text-base-content/70">
            {Fmt.burpee_type(@item.burpee_type)}
          </span>
          <%= if @item.level do %>
            <span class={"inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium #{Fmt.level_color(@item.level)}"}>
              {Fmt.level(@item.level)}
            </span>
          <% end %>
        </div>
      </div>

      <dl class="flex gap-5 text-sm">
        <%= if @item.burpee_count do %>
          <div>
            <dt class="text-xs text-base-content/40 uppercase tracking-wide">Burpees</dt>
            <dd class="font-semibold tabular-nums">{@item.burpee_count}</dd>
          </div>
        <% end %>
        <div>
          <dt class="text-xs text-base-content/40 uppercase tracking-wide">Duration</dt>
          <dd class="font-semibold tabular-nums">{Fmt.duration_sec(@item.duration_sec)}</dd>
        </div>
      </dl>

      <div class="flex gap-2">
        <.link
          navigate={@item.start_path}
          class="flex-1 inline-flex items-center justify-center gap-1.5 rounded-md bg-primary py-2 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
        >
          <.icon name="hero-play" class="size-4" /> Start
        </.link>
        <%= if @item.kind == :plan do %>
          <button
            type="button"
            phx-click="duplicate"
            phx-value-id={@item.id}
            title="Duplicate"
            class="inline-flex items-center justify-center w-9 rounded-md border border-base-300 py-2 hover:bg-base-300 transition"
          >
            <.icon name="hero-document-duplicate" class="size-4" />
          </button>
          <button
            type="button"
            phx-click="delete"
            phx-value-id={@item.id}
            title="Delete"
            data-confirm={"Delete '#{@item.title}'? This cannot be undone."}
            class="inline-flex items-center justify-center w-9 rounded-md border border-error/40 py-2 text-error hover:bg-error/10 transition"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        <% end %>
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
