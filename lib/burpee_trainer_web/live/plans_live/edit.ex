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
  alias BurpeeTrainer.{PlanEditor, PrescriptionGraph}
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
     |> assign(:expanded_timeline_row, nil)
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

  attr(:plan, :any, default: nil)

  defp plan_metadata(%{plan: %WorkoutPlan{plan_solver_metadata: metadata}} = assigns)
       when is_map(metadata) do
    assigns =
      assigns
      |> assign(:source_label, metadata_source_label(metadata["source"]))
      |> assign(:kind_label, metadata_kind_label(assigns.plan.coach_suggestion_kind))
      |> assign(:rationale, List.wrap(metadata["rationale"]))
      |> assign(:risk, metadata["risk"])

    ~H"""
    <section
      id="plan-metadata"
      class="rounded-xl border border-[var(--session-border)] bg-[var(--session-surface)]/45 px-5 py-4"
    >
      <p class="text-sm font-medium text-[var(--session-muted)]">
        Why this?
      </p>
      <p class="mt-2 text-sm font-semibold text-[var(--session-ink)]">
        {@source_label}
      </p>
      <p class="mt-1 text-sm text-[var(--session-muted)]">
        {@kind_label} · {@plan.coach_target_reps} reps
      </p>
      <p :if={@risk} class="mt-1 text-xs text-[var(--session-muted)]">
        Risk: {@risk}
      </p>
      <ul :if={@rationale != []} class="mt-3 space-y-1 text-xs text-[var(--session-muted)]">
        <li :for={line <- @rationale}>{line}</li>
      </ul>
    </section>
    """
  end

  defp plan_metadata(assigns),
    do: ~H"""
    """

  defp metadata_source_label("coach_target"), do: "Coach target"
  defp metadata_source_label("catch_up"), do: "Catch-up"
  defp metadata_source_label(_source), do: "Generated plan"

  defp metadata_kind_label(nil), do: "Generated"
  defp metadata_kind_label(kind), do: kind |> String.replace("_", " ") |> String.capitalize()

  defp change_form_plan(%WorkoutPlan{id: nil} = plan, attrs) do
    plan
    |> Map.put(:blocks, [])
    |> Map.put(:steps, [])
    |> Workouts.change_plan(attrs)
  end

  defp change_form_plan(%WorkoutPlan{} = plan, attrs), do: Workouts.change_plan(plan, attrs)

  defp plan_to_attrs(%WorkoutPlan{} = plan) do
    %{
      "name" => plan.name,
      "burpee_type" => Atom.to_string(plan.burpee_type),
      "target_duration_min" => plan.target_duration_min,
      "burpee_count_target" => plan.burpee_count_target,
      "sec_per_burpee" => plan.sec_per_burpee,
      "pacing_style" => Atom.to_string(plan.pacing_style),
      "additional_rests" => plan.additional_rests,
      "blocks" => blocks_to_attrs(plan.blocks),
      "steps" => steps_to_attrs(plan.steps || [])
    }
  end

  defp steps_to_attrs(steps) do
    steps
    |> Enum.sort_by(& &1.position)
    |> Enum.with_index()
    |> Map.new(fn {step, idx} ->
      attrs = %{
        "position" => step.position,
        "kind" => Atom.to_string(step.kind),
        "block_position" => step.block_position,
        "repeat_count" => step.repeat_count,
        "rest_sec" => step.rest_sec
      }

      attrs = if step.id, do: Map.put(attrs, "id", step.id), else: attrs
      {to_string(idx), attrs}
    end)
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

  defp upsert_editor_rest(rests, index, rest) do
    rests = rests || []

    if index >= 0 and index < length(rests) do
      List.replace_at(rests, index, rest)
    else
      rests ++ [rest]
    end
  end

  defp insert_rest_step(steps, edge_index, rest_sec) do
    sorted_steps = Enum.sort_by(steps || [], & &1.position)
    insert_at = max(edge_index, 0)
    {before_steps, after_steps} = Enum.split(sorted_steps, insert_at)

    reposition_steps(
      before_steps ++
        [%BurpeeTrainer.Workouts.PlanStep{kind: :rest, rest_sec: rest_sec}] ++ after_steps
    )
  end

  defp place_rest_step_at_target_min(steps, blocks, target_min, rest_sec) do
    blocks_by_position = Map.new(blocks || [], &{&1.position, &1})
    target_sec = target_min * 60.0
    rest_step = %BurpeeTrainer.Workouts.PlanStep{kind: :rest, rest_sec: rest_sec}

    steps = steps |> Enum.sort_by(& &1.position) |> merge_adjacent_block_runs()

    case do_place_rest_step(steps, blocks_by_position, target_sec, rest_step, rest_sec) do
      {:ok, placed_steps, adjusted_blocks} ->
        {:ok, reposition_steps(placed_steps),
         adjusted_blocks |> Map.values() |> Enum.sort_by(& &1.position)}

      :not_placed ->
        {:error, "Rest cannot be placed at minute #{round(target_sec / 60)}."}
    end
  end

  defp do_place_rest_step(steps, blocks_by_position, target_sec, rest_step, rest_sec) do
    steps
    |> Enum.reduce_while({[], 0.0, blocks_by_position}, fn step,
                                                           {acc, elapsed, blocks_by_position} ->
      duration = timeline_step_duration(step, blocks_by_position)

      cond do
        step.kind == :block_run and target_sec > elapsed and target_sec < elapsed + duration ->
          block = Map.fetch!(blocks_by_position, step.block_position)
          repeat_duration = max(block_duration(block), 1.0e-6)
          exact_repeat_count = (target_sec - elapsed) / repeat_duration
          before_count = round(exact_repeat_count)

          if abs(before_count - exact_repeat_count) > 1.0e-6 or before_count <= 0 or
               before_count >= step.repeat_count do
            {:halt, :not_placed}
          else
            after_count = step.repeat_count - before_count

            case reclaim_rest_from_prefix(
                   block,
                   before_count,
                   rest_sec,
                   next_block_position(blocks_by_position)
                 ) do
              {:ok, prefix_block} ->
                blocks_by_position =
                  Map.put(blocks_by_position, prefix_block.position, prefix_block)

                split_steps =
                  [
                    %{step | block_position: prefix_block.position, repeat_count: 1},
                    rest_step,
                    %{step | repeat_count: after_count}
                  ]

                {:halt,
                 {:ok, acc ++ split_steps ++ remaining_steps_after(steps, step),
                  blocks_by_position}}

              :error ->
                {:halt, :not_placed}
            end
          end

        target_sec <= elapsed ->
          {:halt,
           {:ok, acc ++ [rest_step, step] ++ remaining_steps_after(steps, step),
            blocks_by_position}}

        true ->
          {:cont, {acc ++ [step], elapsed + duration, blocks_by_position}}
      end
    end)
    |> case do
      {:ok, _steps, _blocks} = ok -> ok
      :not_placed -> :not_placed
      {_acc, _elapsed, _blocks} -> :not_placed
    end
  end

  defp remaining_steps_after(steps, current_step) do
    steps
    |> Enum.drop_while(&(&1 != current_step))
    |> tl()
  end

  defp next_block_position(blocks_by_position) do
    blocks_by_position
    |> Map.keys()
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp reclaim_rest_from_prefix(block, repeat_count, rest_sec, position) do
    sets = Enum.sort_by(block.sets || [], & &1.position)
    expanded_sets = for _round <- 1..repeat_count, set <- sets, do: set

    {adjusted_sets, remaining_rest} =
      Enum.map_reduce(expanded_sets, rest_sec, fn set, remaining ->
        reduction = min(set.end_of_set_rest || 0, remaining)
        {%{set | end_of_set_rest: (set.end_of_set_rest || 0) - reduction}, remaining - reduction}
      end)

    if remaining_rest == 0 do
      adjusted_sets =
        adjusted_sets
        |> Enum.with_index(1)
        |> Enum.map(fn {set, position} -> %{set | id: nil, position: position} end)

      {:ok, %{block | id: nil, position: position, repeat_count: 1, sets: adjusted_sets}}
    else
      :error
    end
  end

  defp merge_adjacent_block_runs(steps) do
    Enum.reduce(steps, [], fn step, acc ->
      case {List.last(acc), step} do
        {%{kind: :block_run, block_position: block_position} = previous,
         %{kind: :block_run, block_position: block_position}} ->
          List.replace_at(acc, -1, %{
            previous
            | repeat_count: previous.repeat_count + step.repeat_count
          })

        _ ->
          acc ++ [step]
      end
    end)
  end

  defp reposition_steps(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.map(fn {step, position} -> %{step | position: position} end)
  end

  defp update_timeline_set(blocks, block_index, set_index, set_params) do
    blocks
    |> Enum.sort_by(& &1.position)
    |> Enum.with_index()
    |> Enum.map(fn {block, idx} ->
      if idx == block_index do
        sets =
          block.sets
          |> Enum.sort_by(& &1.position)
          |> Enum.with_index()
          |> Enum.map(fn {set, set_idx} ->
            if set_idx == set_index do
              %{
                set
                | burpee_count:
                    parse_positive_integer_or(
                      Map.get(set_params, "burpee_count"),
                      set.burpee_count
                    ),
                  sec_per_rep:
                    parse_float_or(Map.get(set_params, "sec_per_rep"), set.sec_per_rep),
                  end_of_set_rest:
                    parse_non_negative_integer_or(
                      Map.get(set_params, "end_of_set_rest"),
                      set.end_of_set_rest
                    )
              }
            else
              set
            end
          end)

        %{block | sets: sets}
      else
        block
      end
    end)
  end

  defp parse_positive_integer_or(value, fallback) do
    case Integer.parse(to_string(value || "")) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> fallback
    end
  end

  defp parse_non_negative_integer_or(value, fallback) do
    case Integer.parse(to_string(value || "")) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> fallback
    end
  end

  defp parse_float_or(value, fallback) do
    case Float.parse(to_string(value || "")) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> fallback
    end
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

  def handle_event("change_block_pattern", params, socket) do
    {:ok, editor} = PlanEditor.change_block_pattern(socket.assigns.editor, params)

    socket =
      socket
      |> put_editor(editor)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("add_pattern_set", _params, socket) do
    input = socket.assigns.editor.input
    pattern = default_pattern(input)
    editor = %{socket.assigns.editor | input: %{input | block_pattern: pattern ++ [1]}}

    socket =
      socket
      |> put_editor(editor)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("remove_pattern_set", %{"index" => index}, socket) do
    input = socket.assigns.editor.input
    pattern = default_pattern(input)

    next_pattern =
      if length(pattern) > 1 do
        pattern
        |> List.delete_at(String.to_integer(index))
        |> case do
          [] -> [1]
          pattern -> pattern
        end
      else
        pattern
      end

    editor = %{socket.assigns.editor | input: %{input | block_pattern: next_pattern}}

    socket =
      socket
      |> put_editor(editor)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
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

  def handle_event(
        "accept_rest_suggestion",
        %{"target-min" => target_min, "rest-sec" => rest_sec},
        socket
      ) do
    rest = %{target_min: String.to_integer(target_min), rest_sec: String.to_integer(rest_sec)}
    input = socket.assigns.editor.input

    editor = %{
      socket.assigns.editor
      | input: %{input | additional_rests: input.additional_rests ++ [rest]}
    }

    {:ok, editor} = PlanEditor.regenerate(editor)

    socket =
      socket
      |> put_editor(editor)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event(
        "add_rest_at",
        %{"target-min" => target_min, "edge-index" => edge_index},
        socket
      ) do
    form_plan = Ecto.Changeset.apply_changes(socket.assigns.form.source)

    if (socket.assigns.live_action == :new and form_plan.pacing_style == :even) or
         (form_plan.steps || []) == [] do
      rest = %{rest_sec: 30, target_min: parse_positive_integer_or(target_min, 1)}
      input = socket.assigns.editor.input

      editor = %{
        socket.assigns.editor
        | input: %{input | additional_rests: input.additional_rests ++ [rest]}
      }

      socket =
        socket
        |> put_editor(editor)
        |> regenerate()
        |> assign_derived()

      {:noreply, socket}
    else
      steps = insert_rest_step(form_plan.steps, String.to_integer(edge_index), 30)
      attrs = form_plan |> plan_to_attrs() |> Map.put("steps", steps_to_attrs(steps))
      changeset = change_form_plan(form_plan, attrs) |> Map.put(:action, :validate)

      {:noreply, socket |> assign(:form, to_form(changeset)) |> assign_derived()}
    end
  end

  def handle_event("change_timeline_rest", %{"rest" => rest_params}, socket) do
    form_plan = Ecto.Changeset.apply_changes(socket.assigns.form.source)
    index = String.to_integer(Map.fetch!(rest_params, "index"))
    rest_sec = parse_positive_integer_or(Map.get(rest_params, "rest_sec"), 30)
    target_min = parse_positive_integer_or(Map.get(rest_params, "target_min"), 1)

    if form_plan.pacing_style == :even do
      rest = %{target_min: target_min, rest_sec: rest_sec}
      input = socket.assigns.editor.input
      rests = upsert_editor_rest(input.additional_rests, index, rest)
      editor = %{socket.assigns.editor | input: %{input | additional_rests: rests}}

      socket =
        socket
        |> put_editor(editor)
        |> regenerate()
        |> assign_derived()

      {:noreply, socket}
    else
      case form_plan.steps
           |> Enum.sort_by(& &1.position)
           |> List.delete_at(index)
           |> place_rest_step_at_target_min(form_plan.blocks, target_min, rest_sec) do
        {:ok, steps, blocks} ->
          attrs =
            form_plan
            |> plan_to_attrs()
            |> Map.put("blocks", blocks_to_attrs(blocks))
            |> Map.put("steps", steps_to_attrs(steps))

          changeset = change_form_plan(form_plan, attrs) |> Map.put(:action, :validate)

          {:noreply,
           socket
           |> assign(:form, to_form(changeset))
           |> assign(:solver_error, nil)
           |> assign_derived()}

        {:error, message} ->
          {:noreply, assign(socket, :solver_error, message)}
      end
    end
  end

  def handle_event("remove_timeline_rest", %{"index" => index}, socket) do
    form_plan = Ecto.Changeset.apply_changes(socket.assigns.form.source)

    steps =
      form_plan.steps |> Enum.sort_by(& &1.position) |> List.delete_at(String.to_integer(index))

    attrs =
      form_plan |> plan_to_attrs() |> Map.put("steps", steps_to_attrs(reposition_steps(steps)))

    changeset = change_form_plan(form_plan, attrs) |> Map.put(:action, :validate)

    {:noreply, socket |> assign(:form, to_form(changeset)) |> assign_derived()}
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

  def handle_event("toggle_timeline_block", %{"row-index" => row_index}, socket) do
    {:noreply, assign(socket, :expanded_timeline_row, String.to_integer(row_index))}
  end

  def handle_event("change_timeline_set", %{"set" => set_params}, socket) do
    form_plan = Ecto.Changeset.apply_changes(socket.assigns.form.source)
    block_index = String.to_integer(Map.fetch!(set_params, "block_index"))
    set_index = String.to_integer(Map.fetch!(set_params, "set_index"))

    blocks = update_timeline_set(form_plan.blocks, block_index, set_index, set_params)
    attrs = form_plan |> plan_to_attrs() |> Map.put("blocks", blocks_to_attrs(blocks))

    changeset = change_form_plan(form_plan, attrs) |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign_derived()

    {:noreply, socket}
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

  def handle_event("save", params, socket) do
    if feasible_prescription?(socket.assigns.derived) do
      submitted_params = Map.get(params, "workout_plan", %{})
      form_plan = Ecto.Changeset.apply_changes(socket.assigns.form.source)

      full_params =
        form_plan
        |> plan_to_attrs()
        |> Map.merge(merge_basics(submitted_params, socket.assigns.editor.input))

      save_plan(socket, socket.assigns.live_action, full_params)
    else
      {:noreply, assign(socket, :solver_error, "Fix prescription before saving")}
    end
  end

  def handle_event("duplicate_plan", _, %{assigns: %{live_action: :edit, plan: plan}} = socket) do
    case Workouts.duplicate_plan(plan) do
      {:ok, copy} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plan copied.")
         |> push_navigate(to: ~p"/workouts/#{copy.id}/edit")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not copy plan.")}
    end
  end

  def handle_event("delete_plan", _, %{assigns: %{live_action: :edit, plan: plan}} = socket) do
    case Workouts.delete_plan(plan) do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plan deleted.")
         |> push_navigate(to: ~p"/workouts")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not delete plan.")}
    end
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

  defp feasible_prescription?(%{both_ok: true}), do: true
  defp feasible_prescription?(_derived), do: false

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
  defp format_sec(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  defp format_sec(v) when is_integer(v), do: :erlang.float_to_binary(v * 1.0, decimals: 1)

  defp format_sec(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> :erlang.float_to_binary(f, decimals: 1)
      _ -> v
    end
  end

  defp format_sec(v), do: v

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  attr(:form, :any, required: true)
  attr(:expanded_blocks, :any, required: true)
  attr(:expanded_timeline_row, :any, required: true)
  attr(:open_block_menu, :any, required: true)
  attr(:plan_input, :map, required: true)
  attr(:manual_edit, :boolean, required: true)
  attr(:derived, :any, required: true)
  attr(:solver_error, :any, required: true)
  attr(:solver_solution, :any, required: true)
  attr(:live_action, :atom, required: true)
  attr(:level, :atom, required: true)

  defp plan_solution_card(assigns) do
    form_plan = Ecto.Changeset.apply_changes(assigns.form.source)
    steps = loaded_steps(form_plan.steps)
    block_time_ranges = block_time_ranges(form_plan.blocks, assigns.plan_input)

    assigns =
      assigns
      |> assign(:block_time_ranges, block_time_ranges)
      |> assign(
        :plan_feedback,
        plan_feedback(assigns.solver_error, assigns.derived, assigns.plan_input)
      )
      |> assign(:pattern_summary, pattern_summary(assigns.plan_input, assigns.derived))
      |> assign(:prescription_blocked?, is_binary(assigns.solver_error))
      |> assign(
        :timeline_rows,
        prescription_timeline(
          form_plan.blocks,
          steps,
          block_time_ranges,
          assigns.derived,
          assigns.plan_input
        )
      )

    plan_solution_card_template(assigns)
  end

  defp default_pattern(%{block_pattern: pattern}) when is_list(pattern) and pattern != [],
    do: pattern

  defp default_pattern(%{reps_per_set: reps}) when is_integer(reps) and reps > 0, do: [reps]
  defp default_pattern(_), do: [1]

  defp pattern_summary(plan_input, derived) do
    pattern = default_pattern(plan_input)
    reps_per_block = Enum.sum(pattern)
    repeats = div(plan_input.burpee_count_target, max(reps_per_block, 1))
    remainder = rem(plan_input.burpee_count_target, max(reps_per_block, 1))
    finish = if derived, do: Fmt.duration_sec(round(derived.duration_sec)), else: "—"
    suffix = if remainder > 0, do: " + remainder #{remainder}", else: ""
    "#{reps_per_block} reps/block · #{repeats}×#{suffix} · #{finish}"
  end

  defp loaded_steps(%Ecto.Association.NotLoaded{}), do: []
  defp loaded_steps(steps) when is_list(steps), do: steps
  defp loaded_steps(_steps), do: []

  defp plan_feedback(solver_error, _derived, _plan_input) when is_binary(solver_error),
    do: feedback_from_message(solver_error)

  defp plan_feedback(nil, %{both_ok: false} = derived, plan_input) do
    duration_message =
      if derived.duration_ok do
        nil
      else
        "Duration is #{Fmt.duration_sec(round(derived.duration_sec))}, target is #{plan_input.target_duration_min}m."
      end

    count_message =
      if derived.count_ok do
        nil
      else
        "Reps are #{derived.burpee_count}, target is #{plan_input.burpee_count_target}."
      end

    %{
      title: "Prescription does not match target",
      message: [duration_message, count_message] |> Enum.reject(&is_nil/1) |> Enum.join(" "),
      actions: ["Adjust the graph", "Regenerate from targets", "Relax duration or reps"]
    }
  end

  defp plan_feedback(_solver_error, _derived, _plan_input), do: nil

  defp feedback_from_message(message) do
    actions =
      cond do
        String.contains?(message, "minimum pace") or String.contains?(message, "needs at least") or
            String.contains?(message, "cannot fit") ->
          ["Increase the duration", "Reduce the rep target", "Choose an easier pace/level"]

        String.contains?(message, "additional rests") or
            String.contains?(message, "Cannot place rest") ->
          ["Move the rest closer to a set boundary", "Shorten the rest", "Increase the duration"]

        true ->
          ["Relax one target", "Adjust duration, reps, pace, or rests"]
      end

    %{title: "No workable prescription", message: message, actions: actions}
  end

  attr(:plan_input, :map, required: true)
  attr(:live_action, :atom, required: true)
  attr(:plan, :any, required: true)

  defp plan_editor_header(assigns) do
    ~H"""
    <.qs_surface class="bg-[var(--session-surface)]/55 px-5 py-5">
      <div class="flex items-start justify-between gap-4">
        <form phx-change="change_basics" class="min-w-0 flex-1 space-y-2">
          <label class="text-sm font-medium text-[var(--session-muted)]">
            Custom session
          </label>
          <input
            type="text"
            name="name"
            value={@plan_input.name}
            class="w-full border-0 bg-transparent px-0 text-3xl font-semibold tracking-[-0.045em] text-[var(--session-ink)] transition placeholder:text-[var(--session-muted)] focus:outline-none"
          />
        </form>
        <div :if={@live_action == :edit} class="flex shrink-0 items-center gap-2">
          <button
            id="plan-duplicate"
            type="button"
            phx-click="duplicate_plan"
            class="rounded-md border border-[var(--session-border)] bg-[var(--session-bg)]/55 px-3 py-2 text-sm font-medium text-[var(--session-muted)] transition hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
          >
            Copy
          </button>
          <button
            id="plan-delete"
            type="button"
            phx-click="delete_plan"
            data-confirm={"Delete '#{@plan.name}'? This cannot be undone."}
            class="rounded-md border border-[var(--session-border)] bg-[var(--session-bg)]/55 px-3 py-2 text-sm font-medium text-[var(--session-muted)] transition hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
          >
            Delete
          </button>
        </div>
      </div>
    </.qs_surface>
    """
  end

  attr(:plan_input, :map, required: true)

  defp plan_type_picker(assigns) do
    ~H"""
    <div class="flex bg-[var(--session-surface)]/40">
      <button
        type="button"
        phx-click="pick_type"
        phx-value-type="six_count"
        class={[
          "flex-1 py-3 text-sm font-medium tracking-wide transition",
          if(@plan_input.burpee_type == :six_count,
            do:
              "bg-[var(--session-toggle-bg)] text-[var(--session-toggle-ink)] ring-1 ring-inset ring-[var(--session-toggle-border)]",
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
            do:
              "bg-[var(--session-toggle-bg)] text-[var(--session-toggle-ink)] ring-1 ring-inset ring-[var(--session-toggle-border)]",
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
      id="plan-goal-controls"
      phx-change="change_basics"
      class="grid grid-cols-2 bg-[var(--session-surface)]/40"
    >
      <div class="border-r border-[var(--session-border)] p-5">
        <p class="mb-3 text-xs font-medium text-[var(--session-muted)]">Duration</p>
        <div class="flex items-baseline gap-1">
          <input
            type="number"
            name="target_duration_min"
            min="1"
            max="120"
            value={@plan_input.target_duration_min}
            class="w-full bg-transparent text-5xl font-semibold leading-none tracking-[-0.05em] tabular-nums text-[var(--session-ink)] focus:outline-none"
          />
          <span class="text-sm text-[var(--session-muted)]">min</span>
        </div>
      </div>
      <div class="p-5">
        <p class="mb-3 text-xs font-medium text-[var(--session-muted)]">Goal</p>
        <input
          type="number"
          name="burpee_count_target"
          min="1"
          value={@plan_input.burpee_count_target}
          class="w-full bg-transparent text-5xl font-semibold leading-none tracking-[-0.05em] tabular-nums text-[var(--session-ink)] focus:outline-none"
        />
      </div>
    </form>
    """
  end

  attr(:plan_input, :map, required: true)

  defp plan_pacing_controls(assigns) do
    ~H"""
    <form phx-change="change_basics" class="bg-[var(--session-surface)]/40">
      <div class="flex">
        <button
          type="button"
          phx-click="pick_pacing"
          phx-value-style="even"
          class={[
            "flex-1 py-3 text-sm font-medium tracking-wide transition",
            if(@plan_input.pacing_style == :even,
              do:
                "bg-[var(--session-toggle-bg)] text-[var(--session-toggle-ink)] ring-1 ring-inset ring-[var(--session-toggle-border)]",
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
              do:
                "bg-[var(--session-toggle-bg)] text-[var(--session-toggle-ink)] ring-1 ring-inset ring-[var(--session-toggle-border)]",
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
            <p class="text-sm font-medium text-[var(--session-muted)]">Per set</p>
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

  attr(:sets, :list, required: true)

  defp block_summary(%{sets: []} = assigns), do: ~H""

  defp block_summary(assigns) do
    sets = assigns.sets
    n = length(sets)
    # Summary rows: group consecutive sets with the same reps, pace, and rest.
    set_groups =
      sets
      |> Enum.with_index(1)
      |> Enum.chunk_by(fn {s, _i} -> {s.burpee_count, s.sec_per_rep, s.end_of_set_rest} end)
      |> Enum.map(fn chunk ->
        {first_s, first_i} = hd(chunk)
        {_last_s, last_i} = List.last(chunk)

        pace =
          if first_s.sec_per_rep && first_s.sec_per_rep > 0, do: first_s.sec_per_rep, else: nil

        {first_i, last_i, first_s.burpee_count, pace, first_s.end_of_set_rest}
      end)

    assigns =
      assign(assigns,
        n: n,
        set_groups: set_groups,
        format_sec: &format_sec/1
      )

    ~H"""
    <div class="space-y-1.5">
      <%= for {from, to, reps, pace, rest} <- @set_groups do %>
        <% count = to - from + 1 %>
        <p class="text-sm tabular-nums text-[var(--session-muted)]">
          <span class="text-[var(--session-muted)] w-8 inline-block">{count}×</span>
          <span class="font-medium text-[var(--session-ink)]">{reps}</span>
          <span class="text-[var(--session-muted)]"> reps</span>
          <%= if pace do %>
            <span class="text-[var(--session-muted)]"> ·</span>
            <span class="text-[var(--session-muted)]">{@format_sec.(pace)}s/rep</span>
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

  defp prescription_timeline(blocks, steps, _block_time_ranges, derived, plan_input) do
    if steps != [] do
      timeline_rows_from_steps(blocks, steps)
    else
      graph_plan = %WorkoutPlan{blocks: blocks}
      finish_sec = if(derived, do: derived.duration_sec, else: 0)

      graph_plan
      |> PrescriptionGraph.build(plan_input.additional_rests, finish_sec)
      |> Map.fetch!(:nodes)
      |> Enum.map(&timeline_row_from_graph_node/1)
    end
  end

  defp timeline_rows_from_steps(blocks, steps) do
    blocks_by_position = Map.new(blocks || [], &{&1.position, &1})

    {rows, elapsed} =
      steps
      |> Enum.sort_by(& &1.position)
      |> Enum.with_index()
      |> Enum.map_reduce(0.0, fn {step, step_index}, elapsed ->
        row = timeline_row_from_step(step, step_index, blocks_by_position, elapsed)
        {row, elapsed + timeline_step_duration(step, blocks_by_position)}
      end)

    [%{kind: :start, time_sec: 0, marker: "Start", title: "Begin", detail: nil}] ++
      rows ++
      [
        %{
          kind: :finish,
          time_sec: elapsed,
          marker: "Finish",
          title: "Predicted finish",
          detail: nil
        }
      ]
  end

  defp timeline_row_from_step(
         %{kind: :block_run} = step,
         _step_index,
         blocks_by_position,
         elapsed
       ) do
    block = Map.fetch!(blocks_by_position, step.block_position)
    block_index = step.block_position - 1
    reps = block_reps_per_repeat(block) * (step.repeat_count || 1)

    %{
      kind: :block,
      block_index: block_index,
      time_sec: elapsed,
      marker: "Block #{step.block_position}",
      title: timeline_block_step_title(step.repeat_count || 1, reps),
      detail: timeline_step_block_detail(block, step),
      sets: timeline_set_rows(Enum.sort_by(block.sets || [], & &1.position))
    }
  end

  defp timeline_row_from_step(%{kind: :rest} = step, step_index, _blocks_by_position, elapsed) do
    %{
      kind: :rest,
      step_index: step_index,
      time_sec: elapsed,
      marker: "Rest",
      title: "+#{step.rest_sec}s recovery",
      detail: nil,
      rest: %{rest_sec: step.rest_sec, target_min: div(round(elapsed), 60)}
    }
  end

  defp timeline_step_duration(%{kind: :block_run} = step, blocks_by_position) do
    block = Map.fetch!(blocks_by_position, step.block_position)
    block_duration(block) * (step.repeat_count || 1)
  end

  defp timeline_step_duration(%{kind: :rest} = step, _blocks_by_position), do: step.rest_sec || 0

  defp timeline_block_step_title(repeat_count, reps) when repeat_count > 1,
    do: "#{repeat_count}× · #{reps} reps"

  defp timeline_block_step_title(_repeat_count, reps), do: "#{reps} reps"

  defp timeline_step_block_detail(block, step) do
    set_count = length(block.sets || [])
    set_text = "#{set_count} #{if set_count == 1, do: "set", else: "sets"}"

    if (step.repeat_count || 1) > 1 do
      "#{set_text} · repeat ×#{step.repeat_count}"
    else
      set_text
    end
  end

  defp block_duration(block) do
    Enum.reduce(block.sets || [], 0.0, fn set, total ->
      total + (set.burpee_count || 0) * (set.sec_per_rep || 0.0) + (set.end_of_set_rest || 0)
    end)
  end

  defp timeline_row_from_graph_node(%PrescriptionGraph.StartNode{} = node) do
    %{kind: :start, time_sec: node.starts_at_sec, marker: "Start", title: "Begin", detail: nil}
  end

  defp timeline_row_from_graph_node(%PrescriptionGraph.FinishNode{} = node) do
    %{
      kind: :finish,
      time_sec: node.starts_at_sec,
      marker: "Finish",
      title: "Predicted finish",
      detail: nil
    }
  end

  defp timeline_row_from_graph_node(%PrescriptionGraph.RestNode{} = node) do
    rest = %{rest_sec: node.duration_sec, target_min: div(round(node.starts_at_sec), 60)}

    %{
      kind: :rest,
      rest_index: node.source_rest_index,
      time_sec: node.starts_at_sec,
      marker: "Rest",
      title: "+#{node.duration_sec}s recovery",
      detail: "at minute #{rest.target_min}",
      rest: rest
    }
  end

  defp timeline_row_from_graph_node(%PrescriptionGraph.BlockRunNode{} = node) do
    sets = Enum.sort_by(node.block.sets, & &1.position)
    source_block_number = node.source_block_index + 1

    marker =
      if timeline_block_run_continued?(node) do
        "Block #{source_block_number} continued"
      else
        "Block #{source_block_number}"
      end

    %{
      kind: :block,
      block_index: node.source_block_index,
      time_sec: node.starts_at_sec,
      marker: marker,
      title: timeline_block_run_title(node),
      detail: timeline_block_run_detail(node),
      sets: timeline_set_rows(sets)
    }
  end

  defp timeline_block_run_continued?(%PrescriptionGraph.BlockRunNode{} = node) do
    first_set_position = node.block.sets |> Enum.map(& &1.position) |> Enum.min(fn -> 1 end)
    node.repeat_from > 1 or first_set_position > 1
  end

  defp timeline_edge_target_min(row, next_row) do
    next_sec = if next_row, do: next_row.time_sec, else: row.time_sec + 60
    midpoint_sec = row.time_sec + max(next_sec - row.time_sec, 60) / 2
    max(1, round(midpoint_sec / 60))
  end

  defp timeline_block_run_title(%PrescriptionGraph.BlockRunNode{} = node) do
    reps = block_reps_per_repeat(node.block) * node.repeat_count

    if node.repeat_count > 1 do
      "#{node.repeat_count}× · #{reps} reps"
    else
      "#{reps} reps"
    end
  end

  defp timeline_block_run_detail(%PrescriptionGraph.BlockRunNode{} = node) do
    set_count = length(node.block.sets || [])
    set_text = "#{set_count} #{if set_count == 1, do: "set", else: "sets"}"

    if node.repeat_count > 1 do
      "#{set_text} · repeats #{node.repeat_from}–#{node.repeat_to}"
    else
      set_text
    end
  end

  defp block_reps_per_repeat(block) do
    Enum.reduce(block.sets || [], 0, fn set, total -> total + (set.burpee_count || 0) end)
  end

  defp timeline_set_rows(sets) do
    sets
    |> Enum.with_index()
    |> Enum.map(fn {set, index} ->
      %{
        index: index,
        set: set,
        title: "Set #{index + 1}",
        detail: timeline_set_detail(set)
      }
    end)
  end

  defp timeline_set_detail(set) do
    pace =
      if set.sec_per_rep && set.sec_per_rep > 0 do
        "#{format_sec(set.sec_per_rep)}s/rep"
      end

    rest =
      if set.end_of_set_rest && set.end_of_set_rest > 0 do
        "#{set.end_of_set_rest}s recovery"
      else
        "no recovery"
      end

    ["#{set.burpee_count} reps", pace, rest]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp group_equal_sets(sets) do
    sets
    |> Enum.chunk_by(fn set ->
      {set.burpee_count, set.sec_per_rep, set.sec_per_burpee, set.end_of_set_rest}
    end)
    |> Enum.map(fn group ->
      first = List.first(group)

      %{
        count: length(group),
        burpee_count: first.burpee_count,
        sec_per_rep: first.sec_per_rep,
        sec_per_burpee: first.sec_per_burpee,
        end_of_set_rest: first.end_of_set_rest,
        positions: Enum.map(group, & &1.position)
      }
    end)
  end
end
