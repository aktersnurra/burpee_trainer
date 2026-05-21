defmodule BurpeeTrainerWeb.PlansLive.Edit do
  @moduledoc """
  Three-layer plan editor.

  Layer 1 — Basics: name, burpee type, target duration, total reps,
    pacing style. Any change re-runs PlanSolver and regenerates
    Layer 3.

  Layer 2 — Additional rests: each entry places a rest at the nearest set
    boundary within 30s of the target minute.
    Any change re-runs the solver and regenerates Layer 3.

  Layer 3 — Blocks: auto-generated from the solver, user-editable.
    Live derived duration and total burpees are shown with constraint
    colour coding. Save is blocked until both constraints pass.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Levels, Planner, Workouts}
  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.PlanSolver.Input
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}
  alias BurpeeTrainerWeb.Fmt

  @impl true
  def mount(params, _session, socket) do
    sessions = Workouts.list_sessions(socket.assigns.current_user)
    level = Levels.current_level(sessions)

    {:ok,
     socket
     |> assign(:live_action, socket.assigns.live_action)
     |> assign(:expanded_blocks, MapSet.new())
     |> assign(:open_block_menu, nil)
     |> assign(:level, level)
     |> load_plan(params)
     |> build_form_from_plan()
     |> assign_derived()}
  end

  defp load_plan(socket, %{"id" => id}) do
    plan =
      socket.assigns.current_user
      |> Workouts.get_plan!(String.to_integer(id))
      |> preload_duration_min()

    plan_input = plan_input_from_plan(plan)

    socket
    |> assign(:plan, plan)
    |> assign(:plan_input, plan_input)
    |> assign(:page_title, "Edit plan")
    |> assign(:solver_error, nil)
    |> assign(:solver_solution, nil)
  end

  defp load_plan(socket, _params) do
    plan_input = default_plan_input()

    socket
    |> assign(:plan, nil)
    |> assign(:plan_input, plan_input)
    |> assign(:page_title, "New plan")
    |> assign(:solver_error, nil)
    |> assign(:solver_solution, nil)
  end

  defp default_plan_input do
    %{
      name: "New plan",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 100,
      pacing_style: :even,
      reps_per_set: PlanSolver.default_reps_per_set(:six_count),
      additional_rests: []
    }
  end

  defp plan_input_from_plan(plan) do
    rests =
      case Jason.decode(plan.additional_rests || "[]") do
        {:ok, list} ->
          Enum.map(list, fn %{"rest_sec" => r, "target_min" => t} ->
            %{rest_sec: r, target_min: t}
          end)

        _ ->
          []
      end

    %{
      name: plan.name,
      burpee_type: plan.burpee_type,
      target_duration_min: plan.target_duration_min || 20,
      burpee_count_target: plan.burpee_count_target || 100,
      pacing_style: plan.pacing_style || :even,
      reps_per_set: infer_reps_per_set(plan),
      additional_rests: rests
    }
  end

  defp infer_reps_per_set(plan) do
    first_set =
      plan.blocks
      |> Enum.sort_by(& &1.position)
      |> List.first()
      |> case do
        nil -> nil
        block -> block.sets |> Enum.sort_by(& &1.position) |> List.first()
      end

    (first_set && first_set.burpee_count) || PlanSolver.default_reps_per_set(plan.burpee_type)
  end

  defp preload_duration_min(%WorkoutPlan{blocks: blocks} = plan) when is_list(blocks) do
    %{plan | blocks: Enum.map(blocks, &preload_block_duration_min/1)}
  end

  defp preload_duration_min(plan), do: plan

  defp preload_block_duration_min(%Block{sets: sets} = block) when is_list(sets) do
    %{block | sets: Enum.map(sets, &preload_set_duration_min/1)}
  end

  defp preload_block_duration_min(block), do: block

  defp preload_set_duration_min(%Set{} = set) do
    total_sec = (set.burpee_count || 0) * (set.sec_per_rep || 0.0) + (set.end_of_set_rest || 0)
    %{set | duration_min: max(1, round(total_sec / 60))}
  end

  # When editing an existing plan: use its blocks directly.
  # When creating: generate from plan_input.
  defp build_form_from_plan(socket) do
    plan = socket.assigns.plan

    if plan do
      changeset = Workouts.change_plan(plan)
      assign(socket, :form, to_form(changeset))
    else
      regenerate(socket)
    end
  end

  # Re-run the solver from plan_input and rebuild the blocks form.
  defp regenerate(socket) do
    plan_input = socket.assigns.plan_input
    level = socket.assigns.level

    solver_input = %Input{
      name: plan_input.name,
      burpee_type: plan_input.burpee_type,
      target_duration_min: plan_input.target_duration_min,
      burpee_count_target: plan_input.burpee_count_target,
      pacing_style: plan_input.pacing_style,
      level: level,
      reps_per_set: plan_input.reps_per_set,
      additional_rests: plan_input.additional_rests
    }

    case PlanSolver.solve(solver_input) do
      {:ok, solution} ->
        base = socket.assigns.plan || %WorkoutPlan{}
        changeset = Workouts.change_plan(%{base | blocks: []}, plan_to_attrs(solution.plan))

        socket
        |> assign(:form, to_form(changeset))
        |> assign(:solver_error, nil)
        |> assign(:solver_solution, solution)

      {:error, reasons} ->
        existing_form =
          socket.assigns[:form] || to_form(Workouts.change_plan(%WorkoutPlan{blocks: []}))

        socket
        |> assign(:form, existing_form)
        |> assign(:solver_error, Enum.join(reasons, "; "))
        |> assign(:solver_solution, nil)
    end
  end

  defp plan_to_attrs(%WorkoutPlan{} = plan) do
    %{
      "name" => plan.name,
      "burpee_type" => Atom.to_string(plan.burpee_type),
      "target_duration_min" => plan.target_duration_min,
      "burpee_count_target" => plan.burpee_count_target,
      "sec_per_burpee" => plan.sec_per_burpee,
      "pacing_style" => Atom.to_string(plan.pacing_style),
      "additional_rests" => plan.additional_rests,
      "blocks" => blocks_to_attrs(plan.blocks)
    }
  end

  defp blocks_to_attrs(blocks) do
    Enum.sort_by(blocks, & &1.position)
    |> Enum.with_index()
    |> Map.new(fn {block, idx} ->
      {to_string(idx),
       %{
         "position" => block.position,
         "repeat_count" => block.repeat_count,
         "sets" =>
           block.sets
           |> Enum.sort_by(& &1.position)
           |> Enum.with_index()
           |> Map.new(fn {set, si} ->
             {to_string(si),
              %{
                "position" => set.position,
                "burpee_count" => set.burpee_count,
                "sec_per_rep" => set.sec_per_rep,
                "sec_per_burpee" => set.sec_per_burpee,
                "end_of_set_rest" => set.end_of_set_rest
              }}
           end)
       }}
    end)
  end

  defp assign_derived(socket) do
    changeset = socket.assigns.form.source
    plan_input = socket.assigns.plan_input

    derived =
      try do
        plan = Ecto.Changeset.apply_changes(changeset)

        if can_summarize?(plan) do
          summary = Planner.summary(plan)
          target_sec = plan_input.target_duration_min * 60
          target_count = plan_input.burpee_count_target

          duration_ok = abs(summary.duration_sec_total - target_sec) <= 5
          count_ok = summary.burpee_count_total == target_count

          %{
            duration_sec: summary.duration_sec_total,
            burpee_count: summary.burpee_count_total,
            target_sec: target_sec,
            target_count: target_count,
            duration_ok: duration_ok,
            count_ok: count_ok,
            both_ok: duration_ok and count_ok
          }
        end
      rescue
        e ->
          require Logger
          Logger.warning("assign_derived failed: #{inspect(e)}")
          nil
      end

    assign(socket, :derived, derived)
  end

  defp can_summarize?(%WorkoutPlan{blocks: blocks}) when is_list(blocks) and blocks != [] do
    Enum.all?(blocks, fn block ->
      is_integer(block.repeat_count) and block.repeat_count > 0 and
        is_list(block.sets) and block.sets != [] and
        Enum.all?(block.sets, fn set ->
          is_integer(set.burpee_count) and set.burpee_count >= 0 and
            is_number(set.sec_per_rep) and set.sec_per_rep > 0 and
            is_number(set.sec_per_burpee) and set.sec_per_burpee > 0 and
            is_number(set.end_of_set_rest)
        end)
    end)
  end

  defp can_summarize?(_), do: false

  # ---------------------------------------------------------------------------
  # Events — Layer 1 & 2
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("change_basics", params, socket) do
    plan_input = parse_basics(params, socket.assigns.plan_input)

    socket =
      socket
      |> assign(:plan_input, plan_input)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("pick_type", %{"type" => type}, socket)
      when type in ["six_count", "navy_seal"] do
    burpee_type = String.to_atom(type)

    plan_input =
      socket.assigns.plan_input
      |> Map.put(:burpee_type, burpee_type)
      |> Map.put(:reps_per_set, PlanSolver.default_reps_per_set(burpee_type))

    socket =
      socket
      |> assign(:plan_input, plan_input)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("pick_pacing", %{"style" => style}, socket)
      when style in ["even", "unbroken"] do
    plan_input = Map.put(socket.assigns.plan_input, :pacing_style, String.to_atom(style))

    socket =
      socket
      |> assign(:plan_input, plan_input)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("add_rest", _, socket) do
    current = socket.assigns.plan_input
    count = length(current.additional_rests) + 1
    # Space new rests evenly: 1st at 50%, 2nd at 33%/66%, etc.
    target_min = max(1, div(current.target_duration_min * count, count + 1))
    new_rest = %{rest_sec: 30, target_min: target_min}
    plan_input = %{current | additional_rests: current.additional_rests ++ [new_rest]}

    socket =
      socket
      |> assign(:plan_input, plan_input)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("remove_rest", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    rests = List.delete_at(socket.assigns.plan_input.additional_rests, idx)
    plan_input = Map.put(socket.assigns.plan_input, :additional_rests, rests)

    socket =
      socket
      |> assign(:plan_input, plan_input)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("change_rest", %{"rest" => rest_params} = _params, socket) do
    idx = rest_params |> Map.get("index", "0") |> String.to_integer()

    existing =
      Enum.at(socket.assigns.plan_input.additional_rests, idx, %{rest_sec: 30, target_min: 10})

    rest_sec =
      case Integer.parse(rest_params["rest_sec"] || "") do
        {n, ""} when n > 0 -> n
        _ -> existing.rest_sec
      end

    target_min =
      case Integer.parse(rest_params["target_min"] || "") do
        {n, ""} when n > 0 -> n
        _ -> existing.target_min
      end

    rests =
      List.update_at(socket.assigns.plan_input.additional_rests, idx, fn _ ->
        %{rest_sec: rest_sec, target_min: target_min}
      end)

    plan_input = Map.put(socket.assigns.plan_input, :additional_rests, rests)

    socket =
      socket
      |> assign(:plan_input, plan_input)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Events — Layer 3
  # ---------------------------------------------------------------------------

  def handle_event("copy_block", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    changeset = socket.assigns.form.source
    plan = Ecto.Changeset.apply_changes(changeset)

    blocks = Enum.sort_by(plan.blocks, & &1.position)
    source_block = Enum.at(blocks, idx)

    if source_block do
      next_pos = length(blocks) + 1

      new_block_attrs = %{
        "position" => next_pos,
        "repeat_count" => source_block.repeat_count,
        "sets" =>
          source_block.sets
          |> Enum.sort_by(& &1.position)
          |> Enum.with_index()
          |> Map.new(fn {set, si} ->
            {to_string(si),
             %{
               "position" => set.position,
               "burpee_count" => set.burpee_count,
               "sec_per_rep" => set.sec_per_rep,
               "sec_per_burpee" => set.sec_per_burpee,
               "end_of_set_rest" => set.end_of_set_rest
             }}
          end)
      }

      new_blocks_attrs = blocks_to_attrs(blocks)
      new_idx = map_size(new_blocks_attrs)
      merged = Map.put(new_blocks_attrs, to_string(new_idx), new_block_attrs)

      params = %{
        "workout_plan" => %{
          "blocks" => merged,
          "blocks_sort" => Enum.map(0..new_idx, &to_string/1)
        }
      }

      handle_event("validate", params, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("copy_set", %{"block_index" => bi_str, "set_index" => si_str}, socket) do
    bi = String.to_integer(bi_str)
    si = String.to_integer(si_str)
    changeset = socket.assigns.form.source
    plan = Ecto.Changeset.apply_changes(changeset)

    blocks = Enum.sort_by(plan.blocks, & &1.position)
    block = Enum.at(blocks, bi)

    if block do
      sets = Enum.sort_by(block.sets, & &1.position)
      source_set = Enum.at(sets, si)

      if source_set do
        new_set_attrs = %{
          "position" => length(sets) + 1,
          "burpee_count" => source_set.burpee_count,
          "sec_per_rep" => source_set.sec_per_rep,
          "sec_per_burpee" => source_set.sec_per_burpee,
          "end_of_set_rest" => source_set.end_of_set_rest
        }

        existing_sets =
          sets
          |> Enum.with_index()
          |> Map.new(fn {set, idx} ->
            {to_string(idx),
             %{
               "position" => set.position,
               "burpee_count" => set.burpee_count,
               "sec_per_rep" => set.sec_per_rep,
               "sec_per_burpee" => set.sec_per_burpee,
               "end_of_set_rest" => set.end_of_set_rest
             }}
          end)

        new_si = map_size(existing_sets)
        merged_sets = Map.put(existing_sets, to_string(new_si), new_set_attrs)

        existing_blocks = blocks_to_attrs(blocks)

        updated_block =
          Map.merge(existing_blocks[to_string(bi)], %{
            "sets" => merged_sets,
            "sets_sort" => Enum.map(0..new_si, &to_string/1)
          })

        merged_blocks = Map.put(existing_blocks, to_string(bi), updated_block)

        params = %{
          "workout_plan" => %{
            "blocks" => merged_blocks,
            "blocks_sort" => Enum.map(0..(length(blocks) - 1), &to_string/1)
          }
        }

        handle_event("validate", params, socket)
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_block_menu", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    open = if socket.assigns.open_block_menu == idx, do: nil, else: idx
    {:noreply, assign(socket, :open_block_menu, open)}
  end

  def handle_event("close_block_menu", _, socket) do
    {:noreply, assign(socket, :open_block_menu, nil)}
  end

  def handle_event("toggle_block_expand", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    expanded = socket.assigns.expanded_blocks

    expanded =
      if MapSet.member?(expanded, idx),
        do: MapSet.delete(expanded, idx),
        else: MapSet.put(expanded, idx)

    {:noreply, assign(socket, :expanded_blocks, expanded)}
  end

  def handle_event("validate", %{"workout_plan" => params}, socket) do
    base_plan = socket.assigns.plan || %WorkoutPlan{}

    changeset =
      base_plan
      |> Workouts.change_plan(merge_basics(params, socket.assigns.plan_input))
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:solver_error, nil)
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("save", %{"workout_plan" => params}, socket) do
    full_params = merge_basics(params, socket.assigns.plan_input)
    save_plan(socket, socket.assigns.live_action, full_params)
  end

  defp save_plan(socket, :new, params) do
    case Workouts.create_plan(socket.assigns.current_user, params) do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plan created.")
         |> push_navigate(to: ~p"/workouts")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> assign_derived()}
    end
  end

  defp save_plan(socket, :edit, params) do
    case Workouts.update_plan(socket.assigns.plan, params) do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plan saved.")
         |> push_navigate(to: ~p"/workouts")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> assign_derived()}
    end
  end

  defp merge_basics(params, plan_input) do
    Map.merge(params, %{
      "name" => plan_input.name,
      "burpee_type" => Atom.to_string(plan_input.burpee_type),
      "target_duration_min" => plan_input.target_duration_min,
      "burpee_count_target" => plan_input.burpee_count_target,
      "pacing_style" => Atom.to_string(plan_input.pacing_style),
      "additional_rests" =>
        Jason.encode!(
          Enum.map(plan_input.additional_rests, fn %{rest_sec: r, target_min: t} ->
            %{"rest_sec" => r, "target_min" => t}
          end)
        )
    })
  end

  defp parse_basics(params, current) do
    name = Map.get(params, "name", current.name)

    target_duration_min =
      case Integer.parse(Map.get(params, "target_duration_min", "")) do
        {n, ""} when n > 0 -> n
        _ -> current.target_duration_min
      end

    burpee_count_target =
      case Integer.parse(Map.get(params, "burpee_count_target", "")) do
        {n, ""} when n > 0 -> n
        _ -> current.burpee_count_target
      end

    reps_per_set =
      case Integer.parse(Map.get(params, "reps_per_set", "")) do
        {n, ""} when n > 0 -> n
        _ -> current.reps_per_set
      end

    %{current | name: name, target_duration_min: target_duration_min,
                burpee_count_target: burpee_count_target, reps_per_set: reps_per_set}
  end

  defp format_sec(nil), do: nil
  defp format_sec(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)
  defp format_sec(v) when is_integer(v), do: :erlang.float_to_binary(v * 1.0, decimals: 2)

  defp format_sec(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> :erlang.float_to_binary(f, decimals: 2)
      _ -> v
    end
  end

  defp format_sec(v), do: v

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_level={@current_level}
      current_page={:plans}
    >
      <div class="space-y-6 max-w-3xl">
        <%!-- Inline-editable plan name as page title --%>
        <div class="flex items-center justify-between gap-4">
          <form phx-change="change_basics" class="flex-1 min-w-0">
            <input
              type="text"
              name="name"
              value={@plan_input.name}
              class="w-full bg-transparent text-2xl font-semibold tracking-tight focus:outline-none border-b border-transparent focus:border-[#1E2535] transition pb-0.5"
            />
          </form>
          <.link
            navigate={~p"/workouts"}
            class="text-sm text-base-content/40 hover:text-base-content transition shrink-0"
          >
            Cancel
          </.link>
        </div>

        <%!-- Single input card --%>
        <section class="rounded-[10px] border border-[#1E2535] bg-base-200 divide-y divide-[#1E2535]">
          <%!-- Type + core inputs --%>
          <form phx-change="change_basics" class="p-5 space-y-4">
            <%!-- Burpee type pill --%>
            <div class="inline-flex rounded-lg border border-[#1E2535] overflow-hidden">
              <button
                type="button"
                phx-click="pick_type"
                phx-value-type="six_count"
                class={[
                  "px-5 py-2 text-sm font-medium transition",
                  if(@plan_input.burpee_type == :six_count,
                    do: "bg-primary/15 text-primary",
                    else: "text-base-content/50 hover:text-base-content hover:bg-base-300"
                  )
                ]}
              >
                6-Count
              </button>
              <div class="w-px bg-[#1E2535]" />
              <button
                type="button"
                phx-click="pick_type"
                phx-value-type="navy_seal"
                class={[
                  "px-5 py-2 text-sm font-medium transition",
                  if(@plan_input.burpee_type == :navy_seal,
                    do: "bg-primary/15 text-primary",
                    else: "text-base-content/50 hover:text-base-content hover:bg-base-300"
                  )
                ]}
              >
                Navy SEAL
              </button>
            </div>

            <div class="grid gap-4 sm:grid-cols-2">
              <div class="space-y-1">
                <label class="text-xs text-base-content/50">Duration (min)</label>
                <input
                  type="number"
                  name="target_duration_min"
                  min="1"
                  max="120"
                  value={@plan_input.target_duration_min}
                  class="w-full rounded-md border border-[#1E2535] bg-base-300 px-3 py-2 text-sm"
                />
              </div>
              <div class="space-y-1">
                <label class="text-xs text-base-content/50">Total burpees</label>
                <input
                  type="number"
                  name="burpee_count_target"
                  min="1"
                  value={@plan_input.burpee_count_target}
                  class="w-full rounded-md border border-[#1E2535] bg-base-300 px-3 py-2 text-sm"
                />
              </div>
              <div class="space-y-1">
                <label class="text-xs text-base-content/50">Your level</label>
                <p class="text-sm font-medium">
                  {Atom.to_string(@level) |> String.replace("_", " ") |> String.upcase()}
                </p>
                <p class="text-xs text-base-content/30">
                  Min pace: {:erlang.float_to_binary(BurpeeTrainer.PlanSolver.sustainable_ceiling(@level) * 1.0, decimals: 1)}s/rep — solver finds optimal pace
                </p>
              </div>
            </div>

            <%!-- Pacing --%>
            <div class="space-y-1.5">
              <div class="inline-flex rounded-lg border border-[#1E2535] overflow-hidden">
                <button
                  type="button"
                  phx-click="pick_pacing"
                  phx-value-style="even"
                  class={[
                    "px-5 py-2 text-sm font-medium transition",
                    if(@plan_input.pacing_style == :even,
                      do: "bg-primary/15 text-primary",
                      else: "text-base-content/50 hover:text-base-content hover:bg-base-300"
                    )
                  ]}
                >
                  Even
                </button>
                <div class="w-px bg-[#1E2535]" />
                <button
                  type="button"
                  phx-click="pick_pacing"
                  phx-value-style="unbroken"
                  class={[
                    "px-5 py-2 text-sm font-medium transition",
                    if(@plan_input.pacing_style == :unbroken,
                      do: "bg-primary/15 text-primary",
                      else: "text-base-content/50 hover:text-base-content hover:bg-base-300"
                    )
                  ]}
                >
                  Unbroken
                </button>
              </div>
              <p class="text-xs text-base-content/30">
                {if @plan_input.pacing_style == :even,
                  do: "Uniform cadence with rest between sets",
                  else: "Sets of N reps, rest between"}
              </p>
            </div>

            <%!-- Reps per set — only for unbroken --%>
            <%= if @plan_input.pacing_style == :unbroken do %>
              <div class="flex items-center gap-3">
                <label class="text-xs text-base-content/50 shrink-0">Reps per set</label>
                <input
                  type="number"
                  name="reps_per_set"
                  min="1"
                  value={@plan_input.reps_per_set}
                  class="w-16 rounded-md border border-[#1E2535] bg-base-300 px-2 py-1.5 text-sm text-center font-semibold"
                />
                <span class="text-xs text-base-content/40">
                  → {@plan_input.burpee_count_target |> div(max(1, @plan_input.reps_per_set || 1))} sets
                  <%= if rem(@plan_input.burpee_count_target, max(1, @plan_input.reps_per_set || 1)) > 0 do %>
                    + 1 partial
                  <% end %>
                </span>
              </div>
            <% end %>
          </form>

          <%!-- Additional rests --%>
          <div class="p-5 space-y-3">
            <div class="flex items-center justify-between">
              <span class="text-xs text-base-content/50 uppercase tracking-wide font-semibold">
                Additional rests
              </span>
              <button
                type="button"
                phx-click="add_rest"
                class="text-xs text-primary hover:underline transition"
              >
                + Add rest
              </button>
            </div>
            <%= if @plan_input.additional_rests == [] do %>
              <p class="text-xs text-base-content/30">
                None — tap + Add rest to insert a pause at a specific minute.
              </p>
            <% end %>
            <%= for {rest, idx} <- Enum.with_index(@plan_input.additional_rests) do %>
              <form phx-change="change_rest" class="flex items-center gap-2 text-sm">
                <input type="hidden" name="rest[index]" value={idx} />
                <input
                  type="number"
                  name="rest[rest_sec]"
                  min="1"
                  value={rest.rest_sec}
                  class="w-16 rounded-md border border-[#1E2535] bg-base-300 px-2 py-1.5 text-sm text-center"
                />
                <span class="text-xs text-base-content/40">s at min</span>
                <input
                  type="number"
                  name="rest[target_min]"
                  min="1"
                  max={@plan_input.target_duration_min - 1}
                  value={rest.target_min}
                  class="w-16 rounded-md border border-[#1E2535] bg-base-300 px-2 py-1.5 text-sm text-center"
                />
                <button
                  type="button"
                  phx-click="remove_rest"
                  phx-value-index={idx}
                  class="text-base-content/30 hover:text-base-content/70 transition"
                  aria-label="Remove rest"
                >
                  <.icon name="hero-trash" class="size-3.5" />
                </button>
              </form>
            <% end %>
          </div>

        </section>

        <%!-- Layer 3 — Solution card --%>
        <section class="rounded-[10px] border border-[#1E2535] bg-base-200">
          <%!-- Solution header --%>
          <div class={[
            "flex items-center gap-3 px-5 py-4 border-b border-[#1E2535]",
            if(@derived && @derived.both_ok, do: "", else: "")
          ]}>
            <%= if @solver_error do %>
              <.icon name="hero-exclamation-triangle" class="size-4 text-error shrink-0" />
              <span class="text-xs font-semibold uppercase tracking-wide text-error">Error</span>
              <span class="text-sm text-base-content/60 ml-1">{@solver_error}</span>
            <% else %>
              <%= if @derived do %>
                <%= if @derived.both_ok do %>
                  <.icon name="hero-check-circle" class="size-4 text-primary shrink-0" />
                  <span class="text-xs font-semibold uppercase tracking-wide text-primary">
                    Solution
                  </span>
                <% else %>
                  <.icon name="hero-exclamation-triangle" class="size-4 text-error shrink-0" />
                  <span class="text-xs font-semibold uppercase tracking-wide text-error">
                    Invalid
                  </span>
                <% end %>
                <span class="text-sm text-base-content/60 ml-1">
                  <span class={
                    if(@derived.duration_ok,
                      do: "text-base-content font-medium",
                      else: "text-error font-medium"
                    )
                  }>
                    {Fmt.duration_sec(round(@derived.duration_sec))}
                  </span>
                  <span class="text-base-content/30"> · </span>
                  <span class={
                    if(@derived.count_ok,
                      do: "text-base-content font-medium",
                      else: "text-error font-medium"
                    )
                  }>
                    {@derived.burpee_count}
                  </span>
                  <span class="text-base-content/50"> burpees</span>
                </span>
              <% end %>
            <% end %>
          </div>

          <%= if @solver_solution do %>
            <div class="px-5 py-3 border-b border-[#1E2535] text-xs text-base-content/50 flex gap-6 flex-wrap">
              <span>Pace: <strong class="text-base-content">{:erlang.float_to_binary(@solver_solution.sec_per_burpee * 1.0, decimals: 2)}s/rep</strong></span>
              <span>Sets: <strong class="text-base-content">{@solver_solution.set_count} × {@solver_solution.set_size}</strong></span>
              <span>Rest/set: <strong class="text-base-content">{round(@solver_solution.rest_sec)}s</strong></span>
            </div>
          <% end %>

          <%!-- Blocks form --%>
          <.form
            for={@form}
            id="plan-form"
            phx-change="validate"
            phx-submit="save"
            class="px-5 pb-5 space-y-4"
          >
            <.blocks_editor
              form={@form}
              expanded_blocks={@expanded_blocks}
              open_block_menu={@open_block_menu}
              plan_input={@plan_input}
            />

            <div class="border-t border-[#1E2535] pt-4 flex items-center justify-between">
              <label class="cursor-pointer rounded-md border border-[#1E2535] px-3 py-1.5 text-sm text-base-content/60 hover:bg-base-300 transition">
                + Add block
                <input type="checkbox" name="workout_plan[blocks_sort][]" class="hidden" />
              </label>
              <div class="flex items-center gap-4">
                <%= if @derived do %>
                  <span class="text-sm tabular-nums text-base-content/50">
                    <span class={if @derived.duration_ok, do: "text-base-content", else: "text-error"}>
                      {Fmt.duration_sec(round(@derived.duration_sec))}
                    </span>
                    <span> · </span>
                    <span class={if @derived.count_ok, do: "text-base-content", else: "text-error"}>
                      {@derived.burpee_count}
                    </span>
                    <span class="text-base-content/30"> burpees</span>
                  </span>
                <% end %>
                <button
                  type="submit"
                  class={[
                    "rounded-md px-6 py-2 text-sm font-medium text-primary-content transition",
                    if(@derived && @derived.both_ok,
                      do: "bg-primary hover:bg-primary/90",
                      else: "bg-base-300 text-base-content/60 cursor-not-allowed"
                    )
                  ]}
                >
                  Save plan
                </button>
              </div>
            </div>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :expanded_blocks, :any, required: true
  attr :open_block_menu, :any, required: true
  attr :plan_input, :map, required: true

  defp blocks_editor(assigns) do
    ~H"""
    <div class="space-y-4">
      <.inputs_for :let={block_f} field={@form[:blocks]}>
        <% expanded = MapSet.member?(@expanded_blocks, block_f.index)
        sets = Ecto.Changeset.apply_changes(block_f.source).sets |> Enum.sort_by(& &1.position)
        uniform = sets_uniform?(sets) %>
        <div class="border-t border-[#1E2535] pt-4 space-y-3">
          <input type="hidden" name="workout_plan[blocks_sort][]" value={block_f.index} />
          <input
            type="hidden"
            name={"workout_plan[blocks][#{block_f.index}][position]"}
            value={block_f.index + 1}
          />

          <%!-- Block header --%>
          <div class="flex items-center justify-between">
            <h3 class="text-sm font-semibold text-base-content/80">
              Block {block_f.index + 1}
            </h3>
            <div class="relative">
              <button
                type="button"
                phx-click="toggle_block_menu"
                phx-value-index={block_f.index}
                class="p-1 text-base-content/30 hover:text-base-content/70 transition rounded"
                aria-label="Block options"
              >
                <.icon name="hero-ellipsis-horizontal" class="size-4" />
              </button>
              <%= if @open_block_menu == block_f.index do %>
                <div
                  phx-click-away="close_block_menu"
                  class="absolute right-0 top-7 z-50 min-w-[140px] rounded-lg border border-[#1E2535] bg-[#0D1017] py-1"
                >
                  <button
                    type="button"
                    phx-click="copy_block"
                    phx-value-index={block_f.index}
                    class="flex w-full items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-[#141B26] transition-colors"
                  >
                    <.icon name="hero-document-duplicate" class="size-4" /> Duplicate
                  </button>
                  <label class="flex w-full cursor-pointer items-center gap-2 px-3 py-2 text-sm text-error/70 hover:text-error hover:bg-[#141B26] transition-colors">
                    <.icon name="hero-trash" class="size-4" /> Remove
                    <input
                      type="checkbox"
                      name="workout_plan[blocks_drop][]"
                      value={block_f.index}
                      class="hidden"
                    />
                  </label>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Repeat count — narrow inline --%>
          <div class="flex items-center gap-2">
            <label class="text-xs text-base-content/40 shrink-0">Repeats</label>
            <input
              type="number"
              name={"workout_plan[blocks][#{block_f.index}][repeat_count]"}
              min="1"
              value={block_f[:repeat_count].value}
              class="w-16 rounded-md border border-[#1E2535] bg-base-300 px-2 py-1 text-sm text-center"
            />
          </div>

          <%!-- Sets section --%>
          <div class="space-y-2">
            <%!-- Column headers + actions on one row --%>
            <div class="flex items-center gap-3">
              <span class="w-6 shrink-0" />
              <%= if uniform && !expanded && length(sets) > 1 do %>
                <%!-- Collapsed: show summary instead of column headers --%>
                <% first = List.first(sets) %>
                <span class="text-xs text-base-content/40 flex-1">
                  <span class="tabular-nums">{length(sets)} ×</span>
                  <span class="tabular-nums">{first.burpee_count}</span>
                  <span> reps</span>
                  <%= if first.end_of_set_rest && first.end_of_set_rest > 0 do %>
                    <span> ·  {first.end_of_set_rest}s rest</span>
                  <% end %>
                </span>
                <button
                  type="button"
                  phx-click="toggle_block_expand"
                  phx-value-index={block_f.index}
                  class="text-xs text-primary hover:underline ml-auto"
                >
                  Edit sets
                </button>
              <% else %>
                <span class="w-14 text-xs text-base-content/30 text-center">Reps</span>
                <span class="w-14 text-xs text-base-content/30 text-center">Rest [s]</span>
                <div class="ml-auto flex items-center gap-3">
                  <%= if uniform && length(sets) > 1 do %>
                    <button
                      type="button"
                      phx-click="toggle_block_expand"
                      phx-value-index={block_f.index}
                      class="text-xs text-base-content/40 hover:text-base-content transition"
                    >
                      Collapse
                    </button>
                  <% end %>
                  <label class="cursor-pointer rounded-md border border-[#1E2535] px-3 py-1 text-xs hover:bg-base-300 transition">
                    + Add set
                    <input
                      type="checkbox"
                      name={"workout_plan[blocks][#{block_f.index}][sets_sort][]"}
                      class="hidden"
                    />
                  </label>
                </div>
              <% end %>
            </div>

            <%!-- Full set rows — always rendered for form submission, hidden when collapsed --%>
            <.inputs_for :let={set_f} field={block_f[:sets]}>
              <% hide_row = uniform && !expanded && length(sets) > 1 %>
              <input
                type="hidden"
                name={"workout_plan[blocks][#{block_f.index}][sets_sort][]"}
                value={set_f.index}
              />
              <input
                type="hidden"
                name={"workout_plan[blocks][#{block_f.index}][sets][#{set_f.index}][position]"}
                value={set_f.index + 1}
              />
              <div class={[
                "flex items-center gap-3 py-1 border-b border-[#1E2535] last:border-0",
                hide_row && "hidden"
              ]}>
                <input
                  type="hidden"
                  name={"workout_plan[blocks][#{block_f.index}][sets][#{set_f.index}][sec_per_rep]"}
                  value={format_sec(set_f[:sec_per_rep].value)}
                />
                <input
                  type="hidden"
                  name={"workout_plan[blocks][#{block_f.index}][sets][#{set_f.index}][sec_per_burpee]"}
                  value={format_sec(set_f[:sec_per_burpee].value)}
                />
                <span class="text-xs text-base-content/30 tabular-nums w-6 shrink-0 text-right">
                  {set_f.index + 1}
                </span>
                <input
                  type="number"
                  name={"workout_plan[blocks][#{block_f.index}][sets][#{set_f.index}][burpee_count]"}
                  value={set_f[:burpee_count].value}
                  min="0"
                  class="w-14 rounded border border-[#1E2535] bg-base-300 px-2 py-1 text-sm text-center tabular-nums"
                />
                <input
                  type="number"
                  name={"workout_plan[blocks][#{block_f.index}][sets][#{set_f.index}][end_of_set_rest]"}
                  value={set_f[:end_of_set_rest].value}
                  min="0"
                  class="w-14 rounded border border-[#1E2535] bg-base-300 px-2 py-1 text-sm text-center tabular-nums"
                />
                <div class="ml-auto flex items-center gap-2">
                  <button
                    type="button"
                    phx-click="copy_set"
                    phx-value-block_index={block_f.index}
                    phx-value-set_index={set_f.index}
                    class="text-base-content/30 hover:text-primary transition"
                    aria-label="Copy set"
                  >
                    <.icon name="hero-document-duplicate" class="size-3.5" />
                  </button>
                  <label class="cursor-pointer text-base-content/30 hover:text-error transition">
                    <.icon name="hero-trash" class="size-3.5" />
                    <input
                      type="checkbox"
                      name={"workout_plan[blocks][#{block_f.index}][sets_drop][]"}
                      value={set_f.index}
                      class="hidden"
                    />
                  </label>
                </div>
              </div>
            </.inputs_for>

            <input
              type="hidden"
              name={"workout_plan[blocks][#{block_f.index}][sets_sort][]"}
              value=""
            />
            <input type="hidden" name={"workout_plan[blocks][#{block_f.index}][sets_drop][]"} />
          </div>
        </div>
      </.inputs_for>

      <input type="hidden" name="workout_plan[blocks_sort][]" value="" />
      <input type="hidden" name="workout_plan[blocks_drop][]" />
    </div>
    """
  end

  defp sets_uniform?([]), do: true
  defp sets_uniform?([_]), do: true

  defp sets_uniform?(sets) do
    first = List.first(sets)

    Enum.all?(sets, fn s ->
      s.burpee_count == first.burpee_count &&
        s.end_of_set_rest == first.end_of_set_rest &&
        s.sec_per_rep == first.sec_per_rep &&
        s.sec_per_burpee == first.sec_per_burpee
    end)
  end
end
