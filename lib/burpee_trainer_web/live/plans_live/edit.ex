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

  alias BurpeeTrainer.{Levels, Workouts}
  alias BurpeeTrainer.PlanEditor
  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}
  alias BurpeeTrainerWeb.Fmt

  embed_templates("edit/*")

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
     |> assign(:manual_edit, false)
     |> load_plan(params)
     |> build_form_from_plan()
     |> assign_derived()}
  end

  defp load_plan(socket, %{"id" => id}) do
    plan =
      socket.assigns.current_user
      |> Workouts.get_plan!(String.to_integer(id))
      |> preload_duration_min()

    {:ok, editor} = PlanEditor.from_plan(plan, socket.assigns.level)

    socket
    |> put_editor(editor)
    |> assign(:page_title, "Edit plan")
    |> assign(:solver_error, editor.solver_error)
    |> assign(:solver_solution, editor.solver_solution)
    |> assign(:manual_edit, editor.manual_edit?)
  end

  defp load_plan(socket, params) do
    {:ok, editor} = PlanEditor.new(socket.assigns.level, params)

    socket
    |> put_editor(editor)
    |> assign(:page_title, "New plan")
    |> assign(:solver_error, editor.solver_error)
    |> assign(:solver_solution, editor.solver_solution)
    |> assign(:manual_edit, editor.manual_edit?)
  end

  # Legacy assigns are mirrored until the remaining LiveView transitions migrate to :editor.
  defp put_editor(socket, editor) do
    socket
    |> assign(:editor, editor)
    |> assign(:plan, editor.plan)
    |> assign(:plan_input, editor.input)
    |> assign(:solver_error, editor.solver_error)
    |> assign(:solver_solution, editor.solver_solution)
    |> assign(:manual_edit, editor.manual_edit?)
    |> assign(:expanded_blocks, editor.expanded_blocks)
    |> assign(:open_block_menu, editor.open_block_menu)
    |> assign(:derived, derived_assign(editor))
  end

  defp derived_assign(%{derived: %{summary: summary}}), do: summary
  defp derived_assign(_editor), do: nil

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

  # Re-run the solver from editor state and rebuild the blocks form.
  defp regenerate(socket) do
    {:ok, editor} = PlanEditor.regenerate(socket.assigns.editor)

    socket = put_editor(socket, editor)

    if editor.solver_solution do
      base = editor.plan || %WorkoutPlan{}

      changeset =
        Workouts.change_plan(%{base | blocks: []}, plan_to_attrs(editor.solver_solution.plan))

      assign(socket, :form, to_form(changeset))
    else
      existing_form =
        socket.assigns[:form] || to_form(Workouts.change_plan(%WorkoutPlan{blocks: []}))

      assign(socket, :form, existing_form)
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

    {derived, form_plan} =
      try do
        form_plan = Ecto.Changeset.apply_changes(changeset)
        {PlanEditor.derived(form_plan, socket.assigns.editor.input), form_plan}
      rescue
        e ->
          require Logger
          Logger.warning("assign_derived failed: #{inspect(e)}")
          {nil, socket.assigns.editor.form_plan}
      end

    editor = %{socket.assigns.editor | derived: derived, form_plan: form_plan}

    socket
    |> assign(:editor, editor)
    |> assign(:derived, derived_assign(editor))
  end

  defp block_time_ranges(blocks, plan_input) do
    _target_sec = plan_input.target_duration_min * 60.0

    {ranges, _acc} =
      blocks
      |> Enum.sort_by(& &1.position)
      |> Enum.map_reduce(0.0, fn block, elapsed ->
        sets = Enum.sort_by(block.sets || [], & &1.position)
        repeat = block.repeat_count || 1

        block_sec =
          Enum.reduce(sets, 0.0, fn s, acc ->
            acc + (s.burpee_count || 0) * (s.sec_per_rep || 0.0) + (s.end_of_set_rest || 0)
          end) * repeat

        range = {elapsed, elapsed + block_sec}
        {range, elapsed + block_sec}
      end)

    ranges
  end

  # ---------------------------------------------------------------------------
  # Events — Layer 1 & 2
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("change_basics", params, socket) do
    {:ok, editor} = PlanEditor.change_basics(socket.assigns.editor, params)

    socket =
      socket
      |> put_editor(editor)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("pick_type", %{"type" => type}, socket) do
    case PlanEditor.pick_type(socket.assigns.editor, type) do
      {:ok, editor} ->
        socket =
          socket
          |> put_editor(editor)
          |> regenerate()
          |> assign_derived()

        {:noreply, socket}

      {:error, _reason, _state} ->
        {:noreply, socket}
    end
  end

  def handle_event("pick_pacing", %{"style" => style}, socket) do
    case PlanEditor.pick_pacing(socket.assigns.editor, style) do
      {:ok, editor} ->
        socket =
          socket
          |> put_editor(editor)
          |> regenerate()
          |> assign_derived()

        {:noreply, socket}

      {:error, _reason, _state} ->
        {:noreply, socket}
    end
  end

  def handle_event("add_rest", _, socket) do
    {:ok, editor} = PlanEditor.add_rest(socket.assigns.editor)

    socket =
      socket
      |> put_editor(editor)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("remove_rest", %{"index" => idx_str}, socket) do
    case PlanEditor.remove_rest(socket.assigns.editor, idx_str) do
      {:ok, editor} ->
        socket =
          socket
          |> put_editor(editor)
          |> regenerate()
          |> assign_derived()

        {:noreply, socket}

      {:error, _reason, _state} ->
        {:noreply, socket}
    end
  end

  def handle_event("change_rest", %{"rest" => rest_params} = _params, socket) do
    case PlanEditor.change_rest(socket.assigns.editor, rest_params) do
      {:ok, editor} ->
        socket =
          socket
          |> put_editor(editor)
          |> regenerate()
          |> assign_derived()

        {:noreply, socket}

      {:error, _reason, _state} ->
        {:noreply, socket}
    end
  end

  def handle_event("set_pace_override", %{"pace" => pace}, socket) do
    {:ok, editor} = PlanEditor.set_pace_override(socket.assigns.editor, pace)

    socket =
      socket
      |> put_editor(editor)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Events — Layer 3
  # ---------------------------------------------------------------------------

  def handle_event("enable_manual_edit", _, socket) do
    {:ok, editor} = PlanEditor.enable_manual_edit(socket.assigns.editor)
    {:noreply, put_editor(socket, editor)}
  end

  def handle_event("copy_block", %{"index" => idx_str}, socket) do
    case PlanEditor.copy_block(socket.assigns.editor, idx_str) do
      {:ok, editor} ->
        validate_editor_form(socket, editor)

      {:error, _reason, _state} ->
        {:noreply, socket}
    end
  end

  def handle_event("copy_set", %{"block_index" => bi_str, "set_index" => si_str}, socket) do
    case PlanEditor.copy_set(socket.assigns.editor, bi_str, si_str) do
      {:ok, editor} ->
        validate_editor_form(socket, editor)

      {:error, _reason, _state} ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_block_menu", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    open = if socket.assigns.editor.open_block_menu == idx, do: nil, else: idx
    editor = %{socket.assigns.editor | open_block_menu: open}

    {:noreply, socket |> put_editor(editor) |> assign(:open_block_menu, open)}
  end

  def handle_event("close_block_menu", _, socket) do
    editor = %{socket.assigns.editor | open_block_menu: nil}
    {:noreply, socket |> put_editor(editor) |> assign(:open_block_menu, nil)}
  end

  def handle_event("toggle_block_expand", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    expanded = socket.assigns.editor.expanded_blocks

    expanded =
      if MapSet.member?(expanded, idx),
        do: MapSet.delete(expanded, idx),
        else: MapSet.put(expanded, idx)

    editor = %{socket.assigns.editor | expanded_blocks: expanded}
    {:noreply, socket |> put_editor(editor) |> assign(:expanded_blocks, expanded)}
  end

  def handle_event("validate", %{"workout_plan" => params}, socket) do
    base_plan = socket.assigns.plan || %WorkoutPlan{}

    changeset =
      base_plan
      |> Workouts.change_plan(merge_basics(params, socket.assigns.editor.input))
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:solver_error, nil)
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("save", %{"workout_plan" => params}, socket) do
    full_params = merge_basics(params, socket.assigns.editor.input)
    save_plan(socket, socket.assigns.live_action, full_params)
  end

  defp validate_editor_form(socket, editor) do
    params = %{"blocks" => blocks_to_attrs(editor.form_plan.blocks)}
    base_plan = editor.plan || %WorkoutPlan{}

    changeset =
      base_plan
      |> Workouts.change_plan(merge_basics(params, editor.input))
      |> Map.put(:action, :validate)

    socket =
      socket
      |> put_editor(editor)
      |> assign(:form, to_form(changeset))
      |> assign(:solver_error, nil)
      |> assign_derived()

    {:noreply, socket}
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
    Map.merge(
      %{
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
      },
      params
    )
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

  attr(:form, :any, required: true)
  attr(:expanded_blocks, :any, required: true)
  attr(:open_block_menu, :any, required: true)
  attr(:plan_input, :map, required: true)
  attr(:manual_edit, :boolean, required: true)
  attr(:derived, :any, required: true)
  attr(:solver_error, :any, required: true)
  attr(:solver_solution, :any, required: true)
  attr(:live_action, :atom, required: true)

  defp plan_solution_card(assigns) do
    assigns =
      assign(
        assigns,
        :block_time_ranges,
        block_time_ranges(
          Ecto.Changeset.apply_changes(assigns.form.source).blocks,
          assigns.plan_input
        )
      )

    plan_solution_card_template(assigns)
  end

  attr(:plan_input, :map, required: true)

  defp plan_editor_header(assigns) do
    ~H"""
    <div class="flex items-end justify-between gap-4 border-b border-[var(--session-border)] pb-4">
      <form phx-change="change_basics" class="min-w-0 flex-1 space-y-1">
        <label class="text-[10px] uppercase tracking-[0.24em] text-[var(--session-muted)]">
          Plan
        </label>
        <input
          type="text"
          name="name"
          value={@plan_input.name}
          class="w-full border-0 border-b border-[var(--session-border)] bg-transparent px-0 pb-1 text-3xl font-semibold tracking-tight text-[var(--session-ink)] transition placeholder:text-[var(--session-muted)] focus:border-[var(--session-ink)] focus:outline-none"
        />
      </form>
      <.link
        navigate={~p"/workouts"}
        class="shrink-0 border border-[var(--session-border)] px-3 py-2 text-sm font-medium text-[var(--session-muted)] transition hover:border-[var(--session-ink)] hover:text-[var(--session-ink)]"
      >
        Cancel
      </.link>
    </div>
    """
  end

  attr(:plan_input, :map, required: true)

  defp plan_type_picker(assigns) do
    ~H"""
    <div class="flex border border-[var(--session-border)] bg-[var(--session-surface)]">
      <button
        type="button"
        phx-click="pick_type"
        phx-value-type="six_count"
        class={[
          "flex-1 py-3 text-sm font-medium tracking-wide transition",
          if(@plan_input.burpee_type == :six_count,
            do: "bg-[var(--session-ink)] text-[var(--session-bg)]",
            else:
              "text-[var(--session-muted)] hover:bg-[var(--session-bg)] hover:text-[var(--session-ink)]"
          )
        ]}
      >
        Six-Count
      </button>
      <div class="w-px bg-[var(--session-border)]" />
      <button
        type="button"
        phx-click="pick_type"
        phx-value-type="navy_seal"
        class={[
          "flex-1 py-3 text-sm font-medium tracking-wide transition",
          if(@plan_input.burpee_type == :navy_seal,
            do: "bg-[var(--session-ink)] text-[var(--session-bg)]",
            else:
              "text-[var(--session-muted)] hover:bg-[var(--session-bg)] hover:text-[var(--session-ink)]"
          )
        ]}
      >
        Navy SEAL
      </button>
    </div>
    """
  end

  attr(:plan_input, :map, required: true)
  attr(:level, :atom, required: true)

  defp plan_goal_controls(assigns) do
    ~H"""
    <form
      phx-change="change_basics"
      class="grid grid-cols-3 border border-[var(--session-border)] bg-[var(--session-surface)]"
    >
      <div class="space-y-1 border-r border-[var(--session-border)] p-5">
        <p class="text-[10px] uppercase tracking-widest text-[var(--session-muted)]">Duration</p>
        <div class="flex items-baseline gap-1">
          <input
            type="number"
            name="target_duration_min"
            min="1"
            max="120"
            value={@plan_input.target_duration_min}
            class="w-full bg-transparent text-4xl font-bold leading-none tabular-nums text-[var(--session-ink)] focus:outline-none"
          />
          <span class="text-sm text-[var(--session-muted)]">min</span>
        </div>
      </div>
      <div class="space-y-1 border-r border-[var(--session-border)] p-5">
        <p class="text-[10px] uppercase tracking-widest text-[var(--session-muted)]">Reps</p>
        <input
          type="number"
          name="burpee_count_target"
          min="1"
          value={@plan_input.burpee_count_target}
          class="w-full bg-transparent text-4xl font-bold leading-none tabular-nums text-[var(--session-ink)] focus:outline-none"
        />
      </div>
      <div class="space-y-1 p-5">
        <p class={[
          "text-[10px] uppercase tracking-widest",
          if(@plan_input.sec_per_burpee_override,
            do: "text-[var(--session-ink)]",
            else: "text-[var(--session-muted)]"
          )
        ]}>
          Pace
        </p>
        <div class="flex items-baseline gap-1">
          <input
            type="number"
            step="0.1"
            min="1"
            phx-change="set_pace_override"
            phx-debounce="500"
            name="pace"
            placeholder={
              :erlang.float_to_binary(
                PlanSolver.effective_ceiling(%BurpeeTrainer.PlanSolver.Input{
                  name: "",
                  burpee_type: @plan_input.burpee_type,
                  target_duration_min: @plan_input.target_duration_min,
                  burpee_count_target: @plan_input.burpee_count_target,
                  pacing_style: @plan_input.pacing_style,
                  level: @level
                }) * 1.0,
                decimals: 1
              )
            }
            value={
              if @plan_input.sec_per_burpee_override,
                do: :erlang.float_to_binary(@plan_input.sec_per_burpee_override * 1.0, decimals: 1),
                else: ""
            }
            class={[
              "w-full bg-transparent text-4xl font-bold leading-none tabular-nums text-[var(--session-ink)] placeholder:text-[var(--session-muted)] focus:outline-none",
              if(@plan_input.sec_per_burpee_override, do: "text-[var(--session-ink)]", else: "")
            ]}
          />
          <div class="flex flex-col items-center gap-0.5">
            <span class="text-sm leading-none text-[var(--session-muted)]">s</span>
            <%= if @plan_input.sec_per_burpee_override do %>
              <button
                type="button"
                phx-click="set_pace_override"
                phx-value-pace=""
                class="text-[var(--session-muted)] transition hover:text-[var(--session-ink)]"
              >
                <.icon name="hero-x-mark" class="size-2.5" />
              </button>
            <% end %>
          </div>
        </div>
      </div>
    </form>
    """
  end

  attr(:plan_input, :map, required: true)

  defp plan_pacing_controls(assigns) do
    ~H"""
    <form
      phx-change="change_basics"
      class="border border-[var(--session-border)] bg-[var(--session-surface)]"
    >
      <div class="flex">
        <button
          type="button"
          phx-click="pick_pacing"
          phx-value-style="even"
          class={[
            "flex-1 py-3 text-sm font-medium tracking-wide transition",
            if(@plan_input.pacing_style == :even,
              do: "bg-[var(--session-ink)] text-[var(--session-bg)]",
              else:
                "text-[var(--session-muted)] hover:bg-[var(--session-bg)] hover:text-[var(--session-ink)]"
            )
          ]}
        >
          Even
        </button>
        <div class="w-px bg-[var(--session-border)]" />
        <button
          type="button"
          phx-click="pick_pacing"
          phx-value-style="unbroken"
          class={[
            "flex-1 py-3 text-sm font-medium tracking-wide transition",
            if(@plan_input.pacing_style == :unbroken,
              do: "bg-[var(--session-ink)] text-[var(--session-bg)]",
              else:
                "text-[var(--session-muted)] hover:bg-[var(--session-bg)] hover:text-[var(--session-ink)]"
            )
          ]}
        >
          Unbroken
        </button>
      </div>
      <%= if @plan_input.pacing_style == :unbroken do %>
        <div class="flex items-baseline justify-between border-t border-[var(--session-border)] px-6 py-5">
          <div class="space-y-1">
            <p class="text-[10px] uppercase tracking-widest text-[var(--session-muted)]">Per set</p>
            <div class="flex items-baseline gap-1.5">
              <input
                type="number"
                name="reps_per_set"
                min="1"
                value={@plan_input.reps_per_set}
                class="w-20 bg-transparent text-3xl font-bold leading-none tabular-nums text-[var(--session-ink)] focus:outline-none"
              />
              <span class="text-sm text-[var(--session-muted)]">reps</span>
            </div>
          </div>
          <span class="text-sm tabular-nums text-[var(--session-muted)]">
            → {@plan_input.burpee_count_target |> div(max(1, @plan_input.reps_per_set || 1))} sets
            <%= if rem(@plan_input.burpee_count_target, max(1, @plan_input.reps_per_set || 1)) > 0 do %>
              <span class="text-[var(--session-muted)]">+ 1</span>
            <% end %>
          </span>
        </div>
      <% end %>
    </form>
    """
  end

  attr(:plan_input, :map, required: true)
  attr(:level, :atom, required: true)

  defp plan_rest_controls(assigns) do
    ~H"""
    <div class="border border-[var(--session-border)] bg-[var(--session-surface)]">
      <div class="border-b border-[var(--session-border)] px-5 py-3">
        <span class="text-xs tabular-nums text-[var(--session-muted)]">
          {Atom.to_string(@level) |> String.replace("_", " ") |> String.upcase()}
          <span class="mx-1 text-[var(--session-muted)]">·</span>
          min {:erlang.float_to_binary(
            BurpeeTrainer.PlanSolver.sustainable_ceiling(@plan_input.burpee_type, @level) * 1.0,
            decimals: 1
          )}s/rep
        </span>
      </div>
      <div class="divide-y divide-[var(--session-border)]">
        <%= for {rest, idx} <- Enum.with_index(@plan_input.additional_rests) do %>
          <form phx-change="change_rest" class="px-5 py-4">
            <input type="hidden" name="rest[index]" value={idx} />
            <div class="flex items-end gap-4">
              <div class="space-y-1">
                <p class="text-[10px] uppercase tracking-widest text-[var(--session-muted)]">Rest</p>
                <div class="flex items-baseline gap-1">
                  <input
                    type="number"
                    name="rest[rest_sec]"
                    min="1"
                    value={rest.rest_sec}
                    class="w-16 bg-transparent text-3xl font-bold leading-none tabular-nums text-[var(--session-ink)] focus:outline-none"
                  />
                  <span class="text-sm text-[var(--session-muted)]">s</span>
                </div>
              </div>
              <span class="mb-1 text-xs text-[var(--session-muted)]">at</span>
              <div class="space-y-1">
                <p class="text-[10px] uppercase tracking-widest text-[var(--session-muted)]">
                  Minute
                </p>
                <div class="flex items-baseline gap-1">
                  <input
                    type="number"
                    name="rest[target_min]"
                    min="1"
                    max={@plan_input.target_duration_min - 1}
                    value={rest.target_min}
                    class="w-16 bg-transparent text-3xl font-bold leading-none tabular-nums text-[var(--session-ink)] focus:outline-none"
                  />
                </div>
              </div>
              <button
                type="button"
                phx-click="remove_rest"
                phx-value-index={idx}
                class="mb-1 ml-auto text-[var(--session-muted)] transition hover:text-[var(--session-ink)]"
                aria-label="Remove rest"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </div>
          </form>
        <% end %>
        <div class="px-5 py-3">
          <button
            type="button"
            phx-click="add_rest"
            class="flex items-center gap-1.5 text-xs text-[var(--session-muted)] transition hover:text-[var(--session-ink)]"
          >
            <.icon name="hero-plus" class="size-3" /> Add rest
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr(:form, :any, required: true)
  attr(:expanded_blocks, :any, required: true)
  attr(:open_block_menu, :any, required: true)
  attr(:plan_input, :map, required: true)
  attr(:manual_edit, :boolean, required: true)
  attr(:block_time_ranges, :list, required: true)

  defp blocks_editor(assigns), do: blocks_editor_template(assigns)

  attr(:sets, :list, required: true)

  defp block_summary(%{sets: []} = assigns), do: ~H""

  defp block_summary(assigns) do
    sets = assigns.sets
    n = length(sets)
    first = List.first(sets)

    # Summary line: N sets of M reps @ Xs/rep
    reps = first.burpee_count
    pace = if first.sec_per_rep && first.sec_per_rep > 0, do: first.sec_per_rep, else: nil

    # Rest rows: group consecutive sets with same rest into ranges
    rest_groups =
      sets
      |> Enum.with_index(1)
      |> Enum.chunk_by(fn {s, _i} -> s.end_of_set_rest end)
      |> Enum.map(fn chunk ->
        {first_s, first_i} = hd(chunk)
        {_last_s, last_i} = List.last(chunk)
        {first_i, last_i, first_s.end_of_set_rest}
      end)

    assigns =
      assign(assigns,
        n: n,
        reps: reps,
        pace: pace,
        rest_groups: rest_groups,
        format_sec: &format_sec/1
      )

    ~H"""
    <div class="space-y-1.5">
      <%= for {from, to, rest} <- @rest_groups do %>
        <% count = to - from + 1 %>
        <p class="text-sm tabular-nums text-[var(--session-muted)]">
          <span class="text-[var(--session-muted)] w-8 inline-block">{count}×</span>
          <span class="font-medium text-[var(--session-ink)]">{@reps}</span>
          <span class="text-[var(--session-muted)]"> reps</span>
          <%= if @pace do %>
            <span class="text-[var(--session-muted)]"> ·</span>
            <span class="text-[var(--session-muted)]">{@format_sec.(@pace)}s/rep</span>
          <% end %>
          <%= cond do %>
            <% rest == 0 || is_nil(rest) -> %>
              <span class="text-[var(--session-muted)]"> ·</span>
              <span class="text-[var(--session-muted)]"> no rest</span>
            <% true -> %>
              <span class="text-[var(--session-muted)]"> ·</span>
              <span class="text-[var(--session-muted)]">{rest}s rest</span>
          <% end %>
        </p>
      <% end %>
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
