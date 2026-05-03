defmodule BurpeeTrainerWeb.PlansLive.Edit do
  @moduledoc """
  Three-layer plan editor.

  Layer 1 — Basics: name, burpee type, target duration, total reps,
    sec/burpee, pacing style. Any change re-runs PlanWizard and regenerates
    Layer 3.

  Layer 2 — Additional rests: each entry places a rest at the nearest set
    boundary within 30s of the target minute.
    Any change re-runs the solver and regenerates Layer 3.

  Layer 3 — Blocks: auto-generated from the solver, user-editable.
    Live derived duration and total burpees are shown with constraint
    colour coding. Save is blocked until both constraints pass.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Planner, Workouts}
  alias BurpeeTrainer.PlanWizard
  alias BurpeeTrainer.PlanWizard.PlanInput
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}
  alias BurpeeTrainerWeb.Fmt

  @sec_per_burpee_floor_six Float.ceil(1200 / 325, 2)
  @sec_per_burpee_floor_navy 1200 / 150

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:live_action, socket.assigns.live_action)
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
  end

  defp load_plan(socket, _params) do
    plan_input = default_plan_input()

    socket
    |> assign(:plan, nil)
    |> assign(:plan_input, plan_input)
    |> assign(:page_title, "New plan")
    |> assign(:solver_error, nil)
  end

  defp default_plan_input do
    %{
      name: "New plan",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 100,
      sec_per_burpee: 5.0,
      pacing_style: :even,
      reps_per_set: PlanWizard.default_reps_per_set(:six_count),
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

    reps_per_set = infer_reps_per_set(plan)

    %{
      name: plan.name,
      burpee_type: plan.burpee_type,
      target_duration_min: plan.target_duration_min || 20,
      burpee_count_target: plan.burpee_count_target || 100,
      sec_per_burpee: plan.sec_per_burpee || 5.0,
      pacing_style: plan.pacing_style || :even,
      reps_per_set: reps_per_set,
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

    (first_set && first_set.burpee_count) || PlanWizard.default_reps_per_set(plan.burpee_type)
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

    wizard_input = %PlanInput{
      name: plan_input.name,
      burpee_type: plan_input.burpee_type,
      target_duration_min: plan_input.target_duration_min,
      burpee_count_target: plan_input.burpee_count_target,
      sec_per_burpee: plan_input.sec_per_burpee,
      pacing_style: plan_input.pacing_style,
      reps_per_set: plan_input.reps_per_set,
      additional_rests: plan_input.additional_rests
    }

    case PlanWizard.generate(wizard_input) do
      {:ok, generated_plan} ->
        base = socket.assigns.plan || %WorkoutPlan{}
        changeset = Workouts.change_plan(%{base | blocks: []}, plan_to_attrs(generated_plan))

        socket
        |> assign(:form, to_form(changeset))
        |> assign(:solver_error, nil)

      {:error, reasons} ->
        # Keep existing blocks form; show solver error
        existing_form =
          socket.assigns[:form] || to_form(Workouts.change_plan(%WorkoutPlan{blocks: []}))

        socket
        |> assign(:form, existing_form)
        |> assign(:solver_error, Enum.join(reasons, "; "))
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
        _ -> nil
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
            is_number(set.sec_per_burpee) and set.sec_per_burpee > 0
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
      |> Map.put(:reps_per_set, PlanWizard.default_reps_per_set(burpee_type))

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

  def handle_event("adjust_pace", %{"delta" => delta_str}, socket) do
    delta = String.to_float(delta_str)
    current = socket.assigns.plan_input.sec_per_burpee
    floor = pace_floor(socket.assigns.plan_input.burpee_type)
    new_val = max(floor, Float.round(current + delta, 2))
    plan_input = Map.put(socket.assigns.plan_input, :sec_per_burpee, new_val)

    socket =
      socket
      |> assign(:plan_input, plan_input)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("adjust_reps_per_set", %{"delta" => delta_str}, socket) do
    delta = String.to_integer(delta_str)

    current =
      socket.assigns.plan_input.reps_per_set ||
        PlanWizard.default_reps_per_set(socket.assigns.plan_input.burpee_type)

    new_val = max(1, current + delta)
    plan_input = Map.put(socket.assigns.plan_input, :reps_per_set, new_val)

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

  def handle_event("validate", %{"workout_plan" => params}, socket) do
    base_plan = socket.assigns.plan || %WorkoutPlan{}

    changeset =
      base_plan
      |> Workouts.change_plan(merge_basics(params, socket.assigns.plan_input))
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("save", %{"workout_plan" => params}, socket) do
    full_params = merge_basics(params, socket.assigns.plan_input)
    save_plan(socket, socket.assigns.live_action, full_params)
  end

  defp save_plan(socket, :new, params) do
    case Workouts.create_plan(socket.assigns.current_user, params) do
      {:ok, plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plan created.")
         |> push_navigate(to: ~p"/plans/#{plan.id}/edit")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> assign_derived()}
    end
  end

  defp save_plan(socket, :edit, params) do
    case Workouts.update_plan(socket.assigns.plan, params) do
      {:ok, plan} ->
        loaded = Workouts.preload_plan(plan)
        plan_input = plan_input_from_plan(loaded)

        {:noreply,
         socket
         |> assign(:plan, preload_duration_min(loaded))
         |> assign(:plan_input, plan_input)
         |> put_flash(:info, "Plan saved.")
         |> build_form_from_plan()
         |> assign_derived()}

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
      "sec_per_burpee" => plan_input.sec_per_burpee,
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

    sec_per_burpee =
      case Float.parse(Map.get(params, "sec_per_burpee", "")) do
        {f, ""} when f > 0 -> f
        _ -> current.sec_per_burpee
      end

    reps_per_set =
      case Integer.parse(Map.get(params, "reps_per_set", "")) do
        {n, ""} when n > 0 -> n
        _ -> current.reps_per_set
      end

    %{
      current
      | name: name,
        target_duration_min: target_duration_min,
        burpee_count_target: burpee_count_target,
        sec_per_burpee: sec_per_burpee,
        reps_per_set: reps_per_set
    }
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

  defp pace_floor(:six_count), do: @sec_per_burpee_floor_six
  defp pace_floor(:navy_seal), do: @sec_per_burpee_floor_navy
  defp pace_floor(_), do: 1.0

  defp pace_floor_label(:six_count),
    do:
      "Min: #{:erlang.float_to_binary(@sec_per_burpee_floor_six * 1.0, decimals: 2)}s (graduation pace)"

  defp pace_floor_label(:navy_seal),
    do:
      "Min: #{:erlang.float_to_binary(@sec_per_burpee_floor_navy * 1.0, decimals: 2)}s (graduation pace)"

  defp pace_floor_label(_), do: ""

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
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-semibold tracking-tight">{@page_title}</h1>
          <.link
            navigate={~p"/plans"}
            class="rounded-md border border-base-300 px-4 py-2 text-sm hover:bg-base-200 transition"
          >
            Cancel
          </.link>
        </div>

        <%!-- Layer 1 — Basics --%>
        <section class="rounded-lg border border-base-300 bg-base-100 p-6 space-y-5">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            1. Basics
          </h2>

          <form phx-change="change_basics" class="space-y-4">
            <div class="grid gap-4 sm:grid-cols-2">
              <div class="space-y-1">
                <label class="text-sm font-medium">Name</label>
                <input
                  type="text"
                  name="name"
                  value={@plan_input.name}
                  class="w-full rounded-md border border-base-300 px-3 py-2 text-sm"
                />
              </div>

              <div class="space-y-1">
                <label class="text-sm font-medium">Target duration (min)</label>
                <input
                  type="number"
                  name="target_duration_min"
                  min="1"
                  max="120"
                  value={@plan_input.target_duration_min}
                  class="w-full rounded-md border border-base-300 px-3 py-2 text-sm"
                />
              </div>

              <div class="space-y-1">
                <label class="text-sm font-medium">Total burpees</label>
                <input
                  type="number"
                  name="burpee_count_target"
                  min="1"
                  value={@plan_input.burpee_count_target}
                  class="w-full rounded-md border border-base-300 px-3 py-2 text-sm"
                />
              </div>

              <div class="space-y-1">
                <label class="text-sm font-medium">Seconds per burpee</label>
                <div class="flex items-center gap-2">
                  <button
                    type="button"
                    phx-click="adjust_pace"
                    phx-value-delta="-0.1"
                    class="rounded-full border border-base-300 w-8 h-8 text-sm font-bold hover:bg-base-200 transition"
                  >
                    −
                  </button>
                  <input
                    type="number"
                    name="sec_per_burpee"
                    step="0.1"
                    min={pace_floor(@plan_input.burpee_type)}
                    value={:erlang.float_to_binary(@plan_input.sec_per_burpee * 1.0, decimals: 2)}
                    class="w-24 rounded-md border border-base-300 px-2 py-1.5 text-sm text-center"
                  />
                  <button
                    type="button"
                    phx-click="adjust_pace"
                    phx-value-delta="0.1"
                    class="rounded-full border border-base-300 w-8 h-8 text-sm font-bold hover:bg-base-200 transition"
                  >
                    +
                  </button>
                </div>
                <p class="text-xs text-base-content/50">
                  {pace_floor_label(@plan_input.burpee_type)}
                </p>
              </div>
            </div>
          </form>

          <div class="space-y-2">
            <label class="text-sm font-medium">Burpee type</label>
            <div class="grid grid-cols-2 gap-3">
              <button
                type="button"
                phx-click="pick_type"
                phx-value-type="six_count"
                class={[
                  "rounded-xl border-2 p-4 text-center transition active:scale-[0.97]",
                  if(@plan_input.burpee_type == :six_count,
                    do: "border-primary bg-primary/5",
                    else: "border-base-300 hover:border-primary hover:bg-primary/5"
                  )
                ]}
              >
                <p class="font-semibold text-sm">6-Count</p>
              </button>
              <button
                type="button"
                phx-click="pick_type"
                phx-value-type="navy_seal"
                class={[
                  "rounded-xl border-2 p-4 text-center transition active:scale-[0.97]",
                  if(@plan_input.burpee_type == :navy_seal,
                    do: "border-primary bg-primary/5",
                    else: "border-base-300 hover:border-primary hover:bg-primary/5"
                  )
                ]}
              >
                <p class="font-semibold text-sm">Navy SEAL</p>
              </button>
            </div>
          </div>

          <div class="space-y-2">
            <label class="text-sm font-medium">Pacing</label>
            <div class="grid grid-cols-2 gap-3">
              <button
                type="button"
                phx-click="pick_pacing"
                phx-value-style="even"
                class={[
                  "rounded-xl border-2 p-4 text-center transition active:scale-[0.97]",
                  if(@plan_input.pacing_style == :even,
                    do: "border-primary bg-primary/5",
                    else: "border-base-300 hover:border-primary hover:bg-primary/5"
                  )
                ]}
              >
                <p class="font-semibold text-sm">Even</p>
                <p class="text-xs text-base-content/60 mt-1">
                  Uniform cadence with rest between sets
                </p>
              </button>
              <button
                type="button"
                phx-click="pick_pacing"
                phx-value-style="unbroken"
                class={[
                  "rounded-xl border-2 p-4 text-center transition active:scale-[0.97]",
                  if(@plan_input.pacing_style == :unbroken,
                    do: "border-primary bg-primary/5",
                    else: "border-base-300 hover:border-primary hover:bg-primary/5"
                  )
                ]}
              >
                <p class="font-semibold text-sm">Unbroken</p>
                <p class="text-xs text-base-content/60 mt-1">Sets of N reps, rest between</p>
              </button>
            </div>
          </div>

          <%= if @plan_input.pacing_style == :unbroken do %>
            <div class="space-y-2">
              <label class="text-sm font-medium">Reps per set</label>
              <div class="flex items-center gap-3">
                <button
                  type="button"
                  phx-click="adjust_reps_per_set"
                  phx-value-delta="-1"
                  class="rounded-full border border-base-300 w-9 h-9 text-lg font-bold hover:bg-base-200 transition"
                >
                  −
                </button>
                <input
                  type="number"
                  name="reps_per_set"
                  min="1"
                  value={@plan_input.reps_per_set}
                  phx-change="change_basics"
                  class="w-20 rounded-md border border-base-300 px-2 py-2 text-sm text-center font-semibold"
                />
                <button
                  type="button"
                  phx-click="adjust_reps_per_set"
                  phx-value-delta="1"
                  class="rounded-full border border-base-300 w-9 h-9 text-lg font-bold hover:bg-base-200 transition"
                >
                  +
                </button>
                <span class="text-sm text-base-content/60">
                  → {@plan_input.burpee_count_target |> div(max(1, @plan_input.reps_per_set || 1))} sets
                  <%= if rem(@plan_input.burpee_count_target, max(1, @plan_input.reps_per_set || 1)) > 0 do %>
                    + 1 partial
                  <% end %>
                </span>
              </div>
            </div>
          <% end %>
        </section>

        <%!-- Layer 2 — Additional rests --%>
        <section class="rounded-lg border border-base-300 bg-base-100 p-6 space-y-4">
          <div class="flex items-center justify-between">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              2. Additional rests
            </h2>
            <button
              type="button"
              phx-click="add_rest"
              class="rounded-md border border-base-300 px-3 py-1 text-sm hover:bg-base-200 transition"
            >
              + Add rest
            </button>
          </div>

          <%= if @plan_input.additional_rests == [] do %>
            <p class="text-sm text-base-content/50">
              No additional rests. Add one to insert a rest pause at a specific minute.
            </p>
          <% end %>

          <%= for {rest, idx} <- Enum.with_index(@plan_input.additional_rests) do %>
            <form phx-change="change_rest" class="flex items-center gap-3 text-sm">
              <input type="hidden" name="rest[index]" value={idx} />
              <input
                type="number"
                name="rest[rest_sec]"
                min="1"
                value={rest.rest_sec}
                class="w-20 rounded-md border border-base-300 px-2 py-1.5 text-sm"
              />
              <span class="text-base-content/60">seconds at min</span>
              <input
                type="number"
                name="rest[target_min]"
                min="1"
                max={@plan_input.target_duration_min - 1}
                value={rest.target_min}
                class="w-20 rounded-md border border-base-300 px-2 py-1.5 text-sm"
              />
              <button
                type="button"
                phx-click="remove_rest"
                phx-value-index={idx}
                class="text-error hover:underline text-xs"
              >
                × remove
              </button>
            </form>
          <% end %>
        </section>

        <%!-- Layer 3 — Blocks --%>
        <section class="space-y-4">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            3. Blocks
          </h2>

          <%= if @solver_error do %>
            <div class="rounded-md bg-error/10 border border-error/30 px-3 py-2 text-sm text-error">
              {@solver_error}
            </div>
          <% end %>

          <.derived_stats derived={@derived} plan_input={@plan_input} />

          <.form
            for={@form}
            id="plan-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-4"
          >
            <.blocks_editor form={@form} />

            <div class="flex justify-end">
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
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :derived, :any, default: nil
  attr :plan_input, :map, required: true

  defp derived_stats(assigns) do
    ~H"""
    <%= if @derived do %>
      <div class={[
        "rounded-lg border p-4 space-y-1 text-sm",
        if(@derived.both_ok, do: "border-success/40 bg-success/5", else: "border-error/40 bg-error/5")
      ]}>
        <div class="flex justify-between">
          <span class="text-base-content/60">Derived duration</span>
          <span class={[
            "font-medium",
            if(@derived.duration_ok, do: "text-success", else: "text-error")
          ]}>
            {Fmt.duration_sec(round(@derived.duration_sec))}
            <span class="text-base-content/50 font-normal text-xs ml-1">
              (target: {@plan_input.target_duration_min}m ±5s)
            </span>
          </span>
        </div>
        <div class="flex justify-between">
          <span class="text-base-content/60">Total burpees</span>
          <span class={[
            "font-medium",
            if(@derived.count_ok, do: "text-success", else: "text-error")
          ]}>
            {@derived.burpee_count}
            <span class="text-base-content/50 font-normal text-xs ml-1">
              (required: {@plan_input.burpee_count_target})
            </span>
          </span>
        </div>
      </div>
    <% end %>
    """
  end

  attr :form, :any, required: true

  defp blocks_editor(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <p class="text-xs text-base-content/60">
          A block repeats its sets <em>repeat count</em> times.
        </p>
        <label class="cursor-pointer rounded-md bg-primary/10 px-3 py-1.5 text-sm text-primary hover:bg-primary/20 transition">
          + Add block <input type="checkbox" name="workout_plan[blocks_sort][]" class="hidden" />
        </label>
      </div>

      <.inputs_for :let={block_f} field={@form[:blocks]}>
        <div class="rounded-lg border border-base-300 bg-base-100 p-5 space-y-4">
          <input type="hidden" name="workout_plan[blocks_sort][]" value={block_f.index} />

          <div class="flex items-center justify-between">
            <h3 class="text-base font-semibold">Block {block_f.index + 1}</h3>
            <div class="flex items-center gap-3">
              <button
                type="button"
                phx-click="copy_block"
                phx-value-index={block_f.index}
                class="text-xs text-primary hover:underline"
              >
                Copy block
              </button>
              <label class="cursor-pointer text-xs text-error hover:underline">
                Remove block
                <input
                  type="checkbox"
                  name="workout_plan[blocks_drop][]"
                  value={block_f.index}
                  class="hidden"
                />
              </label>
            </div>
          </div>

          <input
            type="hidden"
            name={"workout_plan[blocks][#{block_f.index}][position]"}
            value={block_f.index + 1}
          />

          <.input field={block_f[:repeat_count]} type="number" label="Repeat count" min="1" />

          <div class="space-y-3">
            <div class="flex items-center justify-between">
              <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Sets</h4>
              <label class="cursor-pointer rounded-md bg-base-200 px-3 py-1 text-xs hover:bg-base-300 transition">
                + Add set
                <input
                  type="checkbox"
                  name={"workout_plan[blocks][#{block_f.index}][sets_sort][]"}
                  class="hidden"
                />
              </label>
            </div>

            <.inputs_for :let={set_f} field={block_f[:sets]}>
              <div class="rounded-md border border-base-200 bg-base-200/30 p-3">
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

                <div class="grid gap-3 sm:grid-cols-6 items-end">
                  <.input field={set_f[:burpee_count]} type="number" label="Burpees" min="0" />
                  <.input
                    field={set_f[:sec_per_rep]}
                    type="number"
                    label="sec/rep"
                    step="0.01"
                    min="0"
                    value={format_sec(set_f[:sec_per_rep].value)}
                  />
                  <.input
                    field={set_f[:sec_per_burpee]}
                    type="number"
                    label="sec/burpee"
                    step="0.01"
                    min="0"
                    value={format_sec(set_f[:sec_per_burpee].value)}
                  />
                  <.input
                    field={set_f[:end_of_set_rest]}
                    type="number"
                    label="Rest (sec)"
                    min="0"
                  />
                  <button
                    type="button"
                    phx-click="copy_set"
                    phx-value-block_index={block_f.index}
                    phx-value-set_index={set_f.index}
                    class="text-xs text-primary hover:underline pb-3"
                  >
                    Copy
                  </button>
                  <label class="cursor-pointer text-xs text-error hover:underline pb-3">
                    Remove
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
end
