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
  alias BurpeeTrainer.{PlanEditor, PlanPresentation, PlanSolver, PrescriptionGraph}
  alias BurpeeTrainer.PlanCompiler.CompileError
  alias BurpeeTrainer.PlanEditor.Derived
  alias BurpeeTrainer.PlanSolver.Input, as: PlanSolverInput
  alias BurpeeTrainer.PlanEditor.{Block, PlanStep, Set}
  alias BurpeeTrainer.Workouts.WorkoutPlan
  alias BurpeeTrainerWeb.Fmt
  alias BurpeeTrainerWeb.PlansLive.Edit.Presentation

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
     |> assign(:rest_prompt, nil)
     |> assign(:level, level)
     |> assign(:manual_edit, false)
     |> assign(:creator_phase, if(socket.assigns.live_action == :new, do: :intent, else: :editor))
     |> assign(:creator_advanced?, false)
     |> assign(:creator_intent, :planned_session)
     |> assign(:creator_difficulty, 3)
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
    |> assign(:page_title, "Edit workout")
    |> assign(:solver_error, editor.solver_error)
    |> assign(:solver_solution, editor.solver_solution)
    |> assign(:manual_edit, editor.manual_edit?)
  end

  defp load_plan(socket, params) do
    {:ok, editor} = PlanEditor.new(socket.assigns.level, params)

    socket
    |> put_editor(editor)
    |> assign(:page_title, "New workout")
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
    |> assign(:timeline_error, nil)
    |> assign(:solver_solution, editor.solver_solution)
    |> assign(:manual_edit, editor.manual_edit?)
    |> assign(:expanded_blocks, editor.expanded_blocks)
    |> assign(:open_block_menu, editor.open_block_menu)
    |> assign(:selected_block_index, editor.selected_block_index)
    |> assign(:locked_block_indexes, editor.locked_block_indexes)
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

    socket
    |> put_editor(editor)
    |> assign_form_from_editor()
  end

  defp assign_form_from_editor(
         %{assigns: %{editor: %{form_plan: %WorkoutPlan{} = form_plan}}} = socket
       ) do
    editor = socket.assigns.editor
    base = editor.plan || %WorkoutPlan{}
    changeset = change_form_plan(base, editor_form_attrs(%{editor | form_plan: form_plan}))

    assign(socket, :form, to_form(changeset))
  end

  defp assign_form_from_editor(socket) do
    existing_form = socket.assigns[:form] || to_form(Workouts.change_plan(%WorkoutPlan{}))

    assign(socket, :form, existing_form)
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
  defp metadata_source_label(_source), do: "Generated workout"

  defp metadata_kind_label(nil), do: "Generated"
  defp metadata_kind_label(kind), do: kind |> String.replace("_", " ") |> String.capitalize()

  defp change_form_plan(%WorkoutPlan{} = plan, attrs), do: Workouts.change_plan(plan, attrs)

  defp editor_form_attrs(editor, params \\ %{}) do
    editor.form_plan
    |> plan_to_attrs()
    |> Map.merge(params)
    |> Map.merge(editor_source_attrs(editor, params))
  end

  defp editor_save_attrs(editor, params) do
    editor_source_attrs(editor, params)
    |> Map.merge(editor_metadata_attrs(editor))
  end

  defp editor_source_attrs(editor, params) do
    %{
      "name" => Map.get(params, "name") || editor.input.name,
      "source_json" => source_json_from_editor_or_params(editor, params)
    }
  end

  defp source_json_from_editor_or_params(editor, params) do
    case submitted_source_json(params) do
      nil -> source_from_editor(editor)
      source -> normalize_submitted_source(source)
    end
  end

  defp normalize_submitted_source(source) when is_map(source) do
    source
    |> stringify_source_keys()
    |> normalize_submitted_integer("target_reps")
    |> normalize_submitted_integer("target_duration_sec")
    |> normalize_submitted_integer("max_unbroken_reps")
    |> normalize_submitted_float("sec_per_rep_override")
    |> normalize_submitted_block_pattern()
    |> normalize_submitted_explicit_rests()
  end

  defp stringify_source_keys(source) do
    Map.new(source, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_source_value(value)}
      {key, value} -> {to_string(key), stringify_source_value(value)}
    end)
  end

  defp stringify_source_value(value) when is_map(value), do: stringify_source_keys(value)

  defp stringify_source_value(value) when is_list(value),
    do: Enum.map(value, &stringify_source_value/1)

  defp stringify_source_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_source_value(value), do: value

  defp normalize_submitted_integer(source, key) do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(source, key, parse_int(value))
      :error -> source
    end
  end

  defp normalize_submitted_float(source, key) do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(source, key, parse_float(value))
      :error -> source
    end
  end

  defp normalize_submitted_block_pattern(source) do
    case Map.fetch(source, "block_pattern") do
      {:ok, value} -> Map.put(source, "block_pattern", parse_block_pattern(value))
      :error -> source
    end
  end

  defp normalize_submitted_explicit_rests(source) do
    case Map.fetch(source, "explicit_rests") do
      {:ok, value} -> Map.put(source, "explicit_rests", parse_explicit_rests(value))
      :error -> source
    end
  end

  defp submitted_source_json(params) do
    case Map.get(params, "source_json") || Map.get(params, :source_json) do
      source when is_map(source) ->
        source

      source when is_binary(source) ->
        case Jason.decode(source) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp source_from_editor(editor) do
    source =
      editor.input
      |> source_from_input()
      |> put_form_plan_explicit_rests(editor.form_plan)

    if editor.manual_edit? do
      source
      |> maybe_put_manual_block_pattern(editor.form_plan)
      |> maybe_put_manual_pace(editor.form_plan)
    else
      source
    end
  end

  defp maybe_put_manual_block_pattern(source, form_plan) do
    case block_pattern_from_form_plan(form_plan) do
      pattern when is_list(pattern) and pattern != [] -> Map.put(source, "block_pattern", pattern)
      _other -> source
    end
  end

  defp maybe_put_manual_pace(source, form_plan) do
    case pace_override_from_form_plan(form_plan) do
      pace when is_number(pace) ->
        if valid_manual_pace_override?(source, pace) do
          Map.put(source, "sec_per_rep_override", pace)
        else
          source
        end

      nil ->
        source
    end
  end

  defp valid_manual_pace_override?(source, pace) do
    policy = source |> source_burpee_type_for_policy() |> PlanSolver.PacePolicy.for()

    pace >= policy.hard_fastest_sec_per_rep and pace <= policy.hard_slowest_sec_per_rep
  end

  defp source_burpee_type_for_policy(source) do
    case Map.get(source, "burpee_type") || Map.get(source, :burpee_type) do
      :navy_seal -> :navy_seal
      "navy_seal" -> :navy_seal
      _other -> :six_count
    end
  end

  defp block_pattern_from_form_plan(%WorkoutPlan{blocks: blocks}) when is_list(blocks) do
    pattern =
      blocks
      |> Enum.sort_by(&(&1.position || 0))
      |> Enum.flat_map(fn block ->
        motif =
          block.sets
          |> Enum.sort_by(&(&1.position || 0))
          |> Enum.map(& &1.burpee_count)
          |> Enum.reject(&is_nil/1)

        List.duplicate(motif, max(block.repeat_count || 1, 1))
      end)
      |> List.flatten()

    if pattern == [], do: nil, else: pattern
  end

  defp block_pattern_from_form_plan(_form_plan), do: nil

  defp pace_override_from_form_plan(%WorkoutPlan{blocks: blocks}) when is_list(blocks) do
    paces =
      blocks
      |> Enum.flat_map(fn block -> block.sets || [] end)
      |> Enum.map(& &1.sec_per_rep)
      |> Enum.filter(&is_number/1)
      |> Enum.uniq_by(&Float.round(&1 * 1.0, 3))

    case paces do
      [pace] -> pace
      _other -> nil
    end
  end

  defp pace_override_from_form_plan(_form_plan), do: nil

  defp editor_metadata_attrs(editor) do
    form_plan = editor.form_plan || %WorkoutPlan{}

    %{
      "style_name" => form_plan.style_name,
      "coach_suggestion_kind" => form_plan.coach_suggestion_kind,
      "coach_target_reps" => form_plan.coach_target_reps
    }
  end

  defp plan_to_attrs(%WorkoutPlan{} = plan) do
    %{
      "name" => plan.name,
      "source_json" => plan.source_json,
      "burpee_type" => Atom.to_string(plan.burpee_type),
      "target_duration_min" => plan.target_duration_min,
      "burpee_count_target" => plan.burpee_count_target,
      "sec_per_burpee" => plan.sec_per_burpee,
      "pacing_style" => Atom.to_string(plan.pacing_style),
      "blocks" => blocks_to_attrs(plan.blocks),
      "steps" => steps_to_attrs(plan.steps || [])
    }
  end

  defp source_from_input(plan_input) do
    source =
      source_from_form(%{
        "burpee_type" => Atom.to_string(plan_input.burpee_type),
        "target_reps" => plan_input.burpee_count_target,
        "target_duration_sec" => plan_input.target_duration_min * 60,
        "pacing_style" => Atom.to_string(plan_input.pacing_style),
        "block_pattern" =>
          if(plan_input.manual_structure?, do: plan_input.block_pattern, else: nil),
        "explicit_rests" => plan_input.additional_rests || []
      })
      |> Map.put("pace_bias", Atom.to_string(plan_input.pace_bias || :balanced))
      |> Map.put("load_shape", Atom.to_string(plan_input.load_shape || :even))

    source =
      if plan_input.pacing_style == :unbroken do
        Map.put(source, "max_unbroken_reps", plan_input.reps_per_set)
      else
        source
      end

    if plan_input.sec_per_burpee_override do
      Map.put(source, "sec_per_rep_override", plan_input.sec_per_burpee_override)
    else
      source
    end
  end

  defp source_from_form(params) do
    %{
      "burpee_type" => params["burpee_type"],
      "target_reps" => parse_int(params["target_reps"]),
      "target_duration_sec" => parse_int(params["target_duration_sec"]),
      "pacing_style" => params["pacing_style"],
      "block_pattern" => parse_block_pattern(params["block_pattern"]),
      "explicit_rests" => parse_explicit_rests(params["explicit_rests"] || [])
    }
  end

  defp put_form_plan_explicit_rests(source, %WorkoutPlan{} = form_plan) do
    source_rests = parse_explicit_rests(Map.get(source, "explicit_rests") || [])
    form_rests = explicit_rests_from_form_plan(form_plan)

    rests =
      (source_rests ++ form_rests)
      |> Enum.uniq_by(&{&1["target_elapsed_sec"], &1["duration_sec"]})

    Map.put(source, "explicit_rests", rests)
  end

  defp put_form_plan_explicit_rests(source, _form_plan), do: source

  defp explicit_rests_from_form_plan(%WorkoutPlan{steps: steps, blocks: blocks})
       when is_list(steps) do
    blocks_by_position = Map.new(blocks || [], &{&1.position, &1})

    steps
    |> Enum.sort_by(&(&1.position || 0))
    |> Enum.reduce({[], 0.0}, fn
      %{kind: :block_run, block_position: block_position, repeat_count: repeat_count},
      {rests, elapsed} ->
        block = Map.get(blocks_by_position, block_position)
        elapsed = elapsed + block_duration(block) * max(repeat_count || 1, 1)
        {rests, elapsed}

      %{kind: :rest, rest_sec: rest_sec}, {rests, elapsed} ->
        rest = explicit_rest_from_elapsed(elapsed, rest_sec, 60)
        {rests ++ rest, elapsed + (parse_int(rest_sec) || 0)}

      _step, acc ->
        acc
    end)
    |> elem(0)
  end

  defp explicit_rests_from_form_plan(_form_plan), do: []

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value) when is_float(value), do: round(value)

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp parse_float(value) when is_integer(value), do: value * 1.0
  defp parse_float(value) when is_float(value), do: value

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp parse_float(_value), do: nil

  defp parse_block_pattern(nil), do: nil
  defp parse_block_pattern([]), do: nil

  defp parse_block_pattern(values) when is_list(values) do
    values
    |> Enum.map(&parse_int/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      pattern -> pattern
    end
  end

  defp parse_block_pattern(values) when is_map(values) do
    values
    |> Enum.sort_by(fn {index, _value} -> parse_int(index) || 0 end)
    |> Enum.map(fn {_index, value} -> parse_int(value) end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      pattern -> pattern
    end
  end

  defp parse_block_pattern(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&parse_int/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      pattern -> pattern
    end
  end

  defp parse_block_pattern(_value), do: nil

  defp parse_explicit_rests(rests) when is_list(rests) do
    Enum.flat_map(rests, fn
      %{rest_sec: rest_sec, target_min: target_min} ->
        explicit_rest_from_target_min(target_min, rest_sec, 60)

      %{"rest_sec" => rest_sec, "target_min" => target_min} ->
        explicit_rest_from_target_min(target_min, rest_sec, 60)

      %{"target_elapsed_sec" => target, "duration_sec" => duration} = rest ->
        explicit_rest_from_elapsed(target, duration, Map.get(rest, "tolerance_sec") || 60)

      %{target_elapsed_sec: target, duration_sec: duration} = rest ->
        explicit_rest_from_elapsed(target, duration, Map.get(rest, :tolerance_sec) || 60)

      _rest ->
        []
    end)
  end

  defp parse_explicit_rests(_rests), do: []

  defp explicit_rest_from_target_min(target_min, duration_sec, tolerance_sec) do
    case parse_int(target_min) do
      target_min when is_integer(target_min) ->
        explicit_rest_from_elapsed(target_min * 60, duration_sec, tolerance_sec)

      _other ->
        []
    end
  end

  defp explicit_rest_from_elapsed(target_elapsed_sec, duration_sec, tolerance_sec) do
    target_elapsed_sec = parse_int(target_elapsed_sec)
    duration_sec = parse_int(duration_sec)
    tolerance_sec = parse_int(tolerance_sec) || 60

    if is_integer(target_elapsed_sec) and target_elapsed_sec >= 0 and is_integer(duration_sec) and
         duration_sec > 0 do
      [
        %{
          "target_elapsed_sec" => target_elapsed_sec,
          "duration_sec" => duration_sec,
          "tolerance_sec" => tolerance_sec
        }
      ]
    else
      []
    end
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
      block_attrs = %{
        "position" => block.position,
        "repeat_count" => block.repeat_count,
        "sets" =>
          block.sets
          |> Enum.sort_by(& &1.position)
          |> Enum.with_index()
          |> Map.new(fn {set, si} ->
            set_attrs = %{
              "position" => set.position,
              "burpee_count" => set.burpee_count,
              "sec_per_rep" => set.sec_per_rep,
              "sec_per_burpee" => set.sec_per_burpee,
              "end_of_set_rest" => set.end_of_set_rest
            }

            set_attrs = if set.id, do: Map.put(set_attrs, "id", set.id), else: set_attrs
            {to_string(si), set_attrs}
          end)
      }

      block_attrs = if block.id, do: Map.put(block_attrs, "id", block.id), else: block_attrs
      {to_string(idx), block_attrs}
    end)
  end

  defp upsert_editor_rest(rests, index, rest) do
    rests = rests || []

    cond do
      index >= 0 and index < length(rests) ->
        List.replace_at(rests, index, rest) |> dedupe_rests_by_target_min()

      true ->
        (rests ++ [rest]) |> dedupe_rests_by_target_min()
    end
  end

  defp dedupe_rests_by_target_min(rests) do
    rests
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.target_min)
    |> Enum.reverse()
  end

  defp insert_rest_step(steps, edge_index, rest_sec) do
    sorted_steps = Enum.sort_by(steps || [], & &1.position)
    total_executions = block_execution_count(sorted_steps)

    if edge_index <= 0 or edge_index >= total_executions do
      reposition_steps(sorted_steps)
    else
      rest_step = %PlanStep{kind: :rest, rest_sec: rest_sec}

      sorted_steps
      |> insert_rest_after_execution(edge_index, rest_step, [], 0)
      |> merge_adjacent_rest_steps()
      |> reposition_steps()
    end
  end

  defp block_execution_count(steps) do
    steps
    |> Enum.filter(&match?(%{kind: :block_run}, &1))
    |> Enum.reduce(0, fn step, total -> total + max(step.repeat_count || 1, 1) end)
  end

  defp insert_rest_after_execution([], _edge_index, _rest_step, acc, _executions_seen),
    do: Enum.reverse(acc)

  defp insert_rest_after_execution(
         [%{kind: :block_run} = step | remaining],
         edge_index,
         rest_step,
         acc,
         executions_seen
       ) do
    repeat_count = max(step.repeat_count || 1, 1)
    next_seen = executions_seen + repeat_count

    cond do
      edge_index > executions_seen and edge_index < next_seen ->
        before_count = edge_index - executions_seen
        after_count = repeat_count - before_count

        split_steps = [
          %{step | repeat_count: before_count},
          rest_step,
          %{step | id: nil, repeat_count: after_count}
        ]

        Enum.reverse(acc) ++ split_steps ++ remaining

      edge_index == next_seen ->
        Enum.reverse(acc) ++ [step, rest_step] ++ remaining

      true ->
        insert_rest_after_execution(remaining, edge_index, rest_step, [step | acc], next_seen)
    end
  end

  defp insert_rest_after_execution(
         [step | remaining],
         edge_index,
         rest_step,
         acc,
         executions_seen
       ) do
    insert_rest_after_execution(remaining, edge_index, rest_step, [step | acc], executions_seen)
  end

  defp recalibrate_plan_to_target(%WorkoutPlan{} = plan, target_sec)
       when is_number(target_sec) and target_sec > 0 do
    steps = ensure_block_run_steps(plan.steps, plan.blocks)
    blocks_by_position = Map.new(plan.blocks || [], &{&1.position, &1})

    explicit_rest_sec =
      Enum.reduce(steps, 0, fn
        %{kind: :rest, rest_sec: rest_sec}, total -> total + (rest_sec || 0)
        _step, total -> total
      end)

    {total_reps, set_rest_sec} =
      Enum.reduce(steps, {0, 0}, fn
        %{kind: :block_run, block_position: block_position, repeat_count: repeat_count},
        {reps_total, rest_total} ->
          block = Map.get(blocks_by_position, block_position)
          repeat_count = max(repeat_count || 1, 1)

          {
            reps_total + block_reps(block) * repeat_count,
            rest_total + block_set_rest(block) * repeat_count
          }

        _step, acc ->
          acc
      end)

    available_work_sec = target_sec - explicit_rest_sec - set_rest_sec

    if total_reps > 0 and available_work_sec > 0 do
      cadence = available_work_sec / total_reps
      %{plan | blocks: recalibrate_blocks(plan.blocks, cadence)}
    else
      plan
    end
  end

  defp recalibrate_plan_to_target(plan, _target_sec), do: plan

  defp recalibrate_blocks(blocks, cadence) do
    Enum.map(blocks || [], fn block ->
      sets =
        Enum.map(block.sets || [], fn set ->
          sec_per_burpee =
            if is_number(set.sec_per_burpee), do: min(set.sec_per_burpee, cadence), else: cadence

          %{set | sec_per_rep: cadence, sec_per_burpee: sec_per_burpee}
        end)

      %{block | sets: sets}
    end)
  end

  defp block_reps(nil), do: 0

  defp block_reps(block) do
    block.sets
    |> Enum.reduce(0, fn set, total -> total + (set.burpee_count || 0) end)
  end

  defp block_set_rest(nil), do: 0

  defp block_set_rest(block) do
    block.sets
    |> Enum.reduce(0, fn set, total -> total + (set.end_of_set_rest || 0) end)
  end

  defp place_rest_step_at_target_min(steps, blocks, target_min, rest_sec) do
    blocks_by_position = Map.new(blocks || [], &{&1.position, &1})
    target_sec = target_min * 60.0
    rest_step = %PlanStep{kind: :rest, rest_sec: rest_sec}

    steps = steps |> Enum.sort_by(& &1.position) |> merge_adjacent_block_runs()

    case do_place_rest_step(steps, blocks_by_position, target_sec, rest_step, rest_sec) do
      {:ok, placed_steps, adjusted_blocks} ->
        {:ok, reposition_steps(placed_steps),
         adjusted_blocks |> Map.values() |> Enum.sort_by(& &1.position)}

      :not_placed ->
        {:error, rest_placement_error(steps, blocks, target_min, rest_sec)}
    end
  end

  defp rest_placement_error(steps, blocks, target_min, rest_sec) do
    case nearest_workable_rest(steps, blocks, target_min, rest_sec) do
      %{target_min: alt_min, rest_sec: alt_sec} ->
        "Rest cannot be placed at minute #{target_min}. Try #{alt_sec}s at minute #{alt_min} instead."

      nil ->
        "Rest cannot be placed at minute #{target_min}. Try less rest or move it closer to a set boundary."
    end
  end

  defp nearest_workable_rest(steps, blocks, target_min, rest_sec) do
    candidates =
      for minute_delta <- 0..4,
          minute <- candidate_minutes(target_min, minute_delta),
          seconds <- candidate_rest_seconds(rest_sec),
          minute > 0 do
        %{target_min: minute, rest_sec: seconds}
      end

    Enum.find(candidates, fn candidate ->
      rest_step = %PlanStep{kind: :rest, rest_sec: candidate.rest_sec}
      blocks_by_position = Map.new(blocks || [], &{&1.position, &1})
      sorted_steps = steps |> Enum.sort_by(& &1.position) |> merge_adjacent_block_runs()

      case do_place_rest_step(
             sorted_steps,
             blocks_by_position,
             candidate.target_min * 60.0,
             rest_step,
             candidate.rest_sec
           ) do
        {:ok, _steps, _blocks} -> true
        :not_placed -> false
      end
    end)
  end

  defp candidate_minutes(target_min, 0), do: [target_min]
  defp candidate_minutes(target_min, delta), do: [target_min - delta, target_min + delta]

  defp candidate_rest_seconds(rest_sec) do
    [rest_sec, min(rest_sec, 60), min(rest_sec, 45), min(rest_sec, 30), min(rest_sec, 20), 10]
    |> Enum.uniq()
    |> Enum.filter(&(&1 > 0))
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

  defp merge_adjacent_rest_steps(steps) do
    Enum.reduce(steps, [], fn step, acc ->
      case {List.last(acc), step} do
        {%{kind: :rest} = previous, %{kind: :rest}} ->
          List.replace_at(acc, -1, %{previous | rest_sec: previous.rest_sec + step.rest_sec})

        _ ->
          acc ++ [step]
      end
    end)
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

  defp update_block_from_sheet(blocks, block_index, block_params) do
    blocks =
      if is_map(Map.get(block_params, "sets")) do
        update_block_sets(blocks, block_index, Map.get(block_params, "sets"))
      else
        set_params = %{
          "burpee_count" => Map.get(block_params, "reps"),
          "sec_per_rep" => Map.get(block_params, "sec_per_rep"),
          "end_of_set_rest" => Map.get(block_params, "rest_sec")
        }

        update_timeline_block(blocks, block_index, set_params)
      end

    update_block_repeat_count(blocks, block_index, Map.get(block_params, "repeat_count"))
  end

  defp update_segment_from_sheet(%WorkoutPlan{} = form_plan, source_block_index, block_params) do
    case parse_positive_integer(Map.get(block_params, "step_position")) do
      {:ok, step_position} ->
        steps = ensure_block_run_steps(form_plan.steps, form_plan.blocks)

        {blocks, steps, block_index} =
          detach_block_segment(form_plan.blocks, steps, source_block_index, step_position)

        blocks = update_block_from_sheet(blocks, block_index, block_params)
        updated_block = blocks |> Enum.sort_by(&(&1.position || 0)) |> Enum.at(block_index)

        steps =
          update_step_repeat_count(
            steps,
            updated_block && updated_block.position,
            updated_block && updated_block.repeat_count,
            step_position
          )

        %{form_plan | blocks: blocks, steps: steps}

      :error ->
        blocks = update_block_from_sheet(form_plan.blocks, source_block_index, block_params)
        updated_block = blocks |> Enum.sort_by(&(&1.position || 0)) |> Enum.at(source_block_index)

        steps =
          update_step_repeat_count(
            form_plan.steps,
            updated_block && updated_block.position,
            updated_block && updated_block.repeat_count
          )

        %{form_plan | blocks: blocks, steps: steps}
    end
  end

  defp selected_source_block_index(%WorkoutPlan{} = form_plan, block_params, fallback_index) do
    with {:ok, step_position} <- parse_positive_integer(Map.get(block_params, "step_position")),
         %{kind: :block_run, block_position: block_position} <-
           Enum.find(
             form_plan.steps || [],
             &(&1.position == step_position and &1.kind == :block_run)
           ),
         index when is_integer(index) <-
           form_plan.blocks
           |> Enum.sort_by(&(&1.position || 0))
           |> Enum.find_index(&(&1.position == block_position)) do
      index
    else
      _ -> fallback_index
    end
  end

  defp detach_block_segment(blocks, steps, source_block_index, step_position) do
    blocks = Enum.sort_by(blocks || [], &(&1.position || 0))
    steps = Enum.sort_by(steps || [], &(&1.position || 0))
    block = Enum.at(blocks, source_block_index)
    target_step = Enum.find(steps, &(&1.position == step_position and &1.kind == :block_run))

    if block && target_step && target_step.block_position == block.position &&
         shared_block_run?(steps, block.position) do
      cloned_position = next_block_position_from_blocks(blocks)
      cloned_block = clone_block_for_segment(block, cloned_position, target_step.repeat_count)

      steps =
        Enum.map(steps, fn
          %{kind: :block_run, position: ^step_position} = step ->
            %{step | block_position: cloned_position}

          step ->
            step
        end)

      {blocks ++ [cloned_block], steps, length(blocks)}
    else
      {blocks, steps, source_block_index}
    end
  end

  defp shared_block_run?(steps, block_position) do
    steps
    |> Enum.count(&(&1.kind == :block_run and &1.block_position == block_position))
    |> Kernel.>(1)
  end

  defp next_block_position_from_blocks(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&(&1.position || 0))
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp clone_block_for_segment(block, position, repeat_count) do
    sets =
      block.sets
      |> Enum.sort_by(&(&1.position || 0))
      |> Enum.with_index(1)
      |> Enum.map(fn {set, set_position} ->
        %{
          set
          | id: nil,
            block_id: nil,
            position: set_position,
            inserted_at: nil,
            updated_at: nil
        }
      end)

    %{
      block
      | id: nil,
        plan_id: nil,
        position: position,
        repeat_count: repeat_count || block.repeat_count || 1,
        sets: sets,
        inserted_at: nil,
        updated_at: nil
    }
  end

  defp parse_positive_integer(value) do
    case Integer.parse(to_string(value || "")) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp update_step_repeat_count(steps, block_position, repeat_count, step_position)
       when is_list(steps) and is_integer(block_position) and is_integer(repeat_count) and
              is_integer(step_position) do
    Enum.map(steps, fn
      %{kind: :block_run, position: ^step_position, block_position: ^block_position} = step ->
        %{step | repeat_count: repeat_count}

      step ->
        step
    end)
  end

  defp update_step_repeat_count(steps, block_position, repeat_count)
       when is_list(steps) and is_integer(block_position) and is_integer(repeat_count) do
    Enum.map(steps, fn
      %{kind: :block_run, block_position: ^block_position} = step ->
        %{step | repeat_count: repeat_count}

      step ->
        step
    end)
  end

  defp update_step_repeat_count(steps, _block_position, _repeat_count), do: steps

  defp update_block_sets(blocks, block_index, sets_params) do
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
            params = Map.get(sets_params, Integer.to_string(set_idx), %{})

            %{
              set
              | position: set_idx + 1,
                burpee_count:
                  parse_positive_integer_or(Map.get(params, "burpee_count"), set.burpee_count),
                sec_per_rep: parse_float_or(Map.get(params, "sec_per_rep"), set.sec_per_rep),
                sec_per_burpee:
                  parse_float_or(
                    Map.get(params, "sec_per_burpee") || Map.get(params, "sec_per_rep"),
                    set.sec_per_burpee
                  ),
                end_of_set_rest:
                  parse_non_negative_integer_or(
                    Map.get(params, "end_of_set_rest"),
                    set.end_of_set_rest
                  )
            }
          end)

        %{block | sets: sets}
      else
        block
      end
    end)
  end

  defp update_block_repeat_count(blocks, block_index, repeat_count) do
    blocks
    |> Enum.sort_by(& &1.position)
    |> Enum.with_index()
    |> Enum.map(fn {block, idx} ->
      if idx == block_index do
        %{block | repeat_count: parse_positive_integer_or(repeat_count, block.repeat_count || 1)}
      else
        block
      end
    end)
  end

  defp update_timeline_block(blocks, block_index, set_params) do
    blocks
    |> Enum.sort_by(& &1.position)
    |> Enum.with_index()
    |> Enum.map(fn {block, idx} ->
      if idx == block_index do
        sets = Enum.sort_by(block.sets || [], & &1.position)

        case List.first(sets) do
          nil ->
            block

          first_set ->
            set = %{
              first_set
              | position: 1,
                burpee_count:
                  parse_positive_integer_or(
                    Map.get(set_params, "burpee_count"),
                    Enum.reduce(sets, 0, &((&1.burpee_count || 0) + &2))
                  ),
                sec_per_rep:
                  parse_float_or(Map.get(set_params, "sec_per_rep"), first_set.sec_per_rep),
                sec_per_burpee:
                  parse_float_or(
                    Map.get(set_params, "sec_per_burpee") || Map.get(set_params, "sec_per_rep"),
                    first_set.sec_per_burpee
                  ),
                end_of_set_rest:
                  parse_non_negative_integer_or(
                    Map.get(set_params, "end_of_set_rest"),
                    List.last(sets).end_of_set_rest
                  )
            }

            %{block | sets: [set]}
        end
      else
        block
      end
    end)
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
                  sec_per_burpee:
                    parse_float_or(
                      Map.get(set_params, "sec_per_burpee") || Map.get(set_params, "sec_per_rep"),
                      set.sec_per_burpee
                    ),
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

  defp rest_placement_edges(steps) do
    total_executions = block_execution_count(steps)

    {edges, _seen} =
      steps
      |> Enum.sort_by(&(&1.position || 0))
      |> Enum.reduce({[], 0}, fn
        %{kind: :block_run} = step, {edges, seen} ->
          repeat_count = max(step.repeat_count || 1, 1)

          step_edges =
            for offset <- 1..repeat_count,
                edge_index = seen + offset,
                edge_index < total_executions do
              %{
                edge_index: edge_index,
                label: "After block #{edge_index} of #{total_executions}",
                default?: edge_index == max(1, div(total_executions, 2))
              }
            end

          {edges ++ step_edges, seen + repeat_count}

        _step, acc ->
          acc
      end)

    edges
  end

  defp ensure_block_run_steps(steps, _blocks) when is_list(steps) and steps != [], do: steps

  defp ensure_block_run_steps(_steps, blocks) do
    blocks
    |> Enum.sort_by(&(&1.position || 0))
    |> Enum.with_index(1)
    |> Enum.map(fn {block, position} ->
      %PlanStep{
        position: position,
        kind: :block_run,
        block_position: block.position || position,
        repeat_count: block.repeat_count || 1
      }
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

  defp parse_non_negative_index(value) do
    case Integer.parse(to_string(value || "")) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_float_or(value, fallback) do
    case Float.parse(to_string(value || "")) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> fallback
    end
  end

  defp assign_derived(socket) do
    form_plan = socket.assigns.editor.form_plan

    derived =
      cond do
        socket.assigns.solver_error ->
          %Derived{}

        match?(%WorkoutPlan{}, form_plan) ->
          PlanEditor.derived(form_plan, socket.assigns.editor.input)

        true ->
          nil
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
  def handle_event("toggle_advanced_constraints", _params, socket) do
    {:noreply, update(socket, :creator_advanced?, &(!&1))}
  end

  def handle_event("pick_creator_intent", %{"intent" => intent}, socket) do
    intent =
      case intent do
        "catch_up" -> :catch_up
        "easy_technique" -> :easy_technique
        "max_reps" -> :max_reps
        _ -> :planned_session
      end

    {:noreply, assign(socket, :creator_intent, intent)}
  end

  def handle_event("set_creator_difficulty", %{"difficulty" => difficulty}, socket) do
    difficulty =
      case Integer.parse(to_string(difficulty || "")) do
        {value, ""} when value in 1..5 -> value
        _ -> socket.assigns.creator_difficulty
      end

    {:noreply, assign(socket, :creator_difficulty, difficulty)}
  end

  def handle_event("set_pace_bias", %{"bias" => bias}, socket) do
    bias =
      case to_string(bias) do
        "1" -> "slower"
        "2" -> "balanced"
        "3" -> "faster"
        other -> other
      end

    case PlanEditor.set_pace_bias(socket.assigns.editor, bias) do
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

  def handle_event("set_load_shape", %{"shape" => shape}, socket) do
    case PlanEditor.set_load_shape(socket.assigns.editor, shape) do
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

  def handle_event("set_structure_mode", %{"mode" => "auto"}, socket) do
    input = socket.assigns.editor.input

    editor = %{
      socket.assigns.editor
      | input: %{input | block_pattern: nil, manual_structure?: false}
    }

    socket =
      socket
      |> put_editor(editor)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("set_structure_mode", %{"mode" => "pattern"}, socket) do
    input = socket.assigns.editor.input
    pattern = default_pattern(input)

    editor = %{
      socket.assigns.editor
      | input: %{input | block_pattern: pattern, manual_structure?: true}
    }

    socket =
      socket
      |> put_editor(editor)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("generate_workout", _params, socket) do
    {:noreply, assign(socket, :creator_phase, :review)}
  end

  def handle_event("edit_generated_workout", _params, socket) do
    {:noreply, assign(socket, :creator_phase, :editor)}
  end

  def handle_event("select_block", %{"index" => index}, socket) do
    case PlanEditor.select_block(socket.assigns.editor, index) do
      {:ok, editor} ->
        editor = %{editor | open_block_menu: nil}
        {:noreply, socket |> put_editor(editor) |> assign(:open_block_menu, nil)}

      {:error, _reason, _state} ->
        {:noreply, socket}
    end
  end

  def handle_event("close_block_sheet", _params, socket) do
    {:ok, editor} = PlanEditor.close_block(socket.assigns.editor)
    {:noreply, put_editor(socket, editor)}
  end

  def handle_event("toggle_block_lock", %{"index" => index}, socket) do
    case parse_non_negative_index(index) do
      {:ok, source_block_index} ->
        index = Integer.to_string(source_block_index)
        locked? = MapSet.member?(socket.assigns.locked_block_indexes, source_block_index)

        result =
          if locked?,
            do: PlanEditor.unlock_block(socket.assigns.editor, index),
            else: PlanEditor.lock_block(socket.assigns.editor, index)

        case result do
          {:ok, editor} -> validate_editor_form(socket, editor)
          {:error, _reason, _state} -> {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("change_block_sheet", %{"block" => block_params}, socket) do
    form_plan = socket.assigns.editor.form_plan

    with {:ok, source_block_index} <-
           parse_non_negative_index(Map.get(block_params, "source_block_index")),
         true <- source_block_index < length(form_plan.blocks) do
      form_plan = update_segment_from_sheet(form_plan, source_block_index, block_params)
      editor = %{socket.assigns.editor | form_plan: form_plan, manual_edit?: true}
      lock_index = selected_source_block_index(form_plan, block_params, source_block_index)

      case PlanEditor.lock_block(editor, Integer.to_string(lock_index)) do
        {:ok, editor} -> validate_editor_form(socket, editor)
        {:error, _reason, _state} -> {:noreply, socket}
      end
    else
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("rebalance_unlocked_blocks", _params, socket) do
    {:ok, editor} = PlanEditor.rebalance_unlocked_blocks(socket.assigns.editor)
    validate_editor_form(socket, editor)
  end

  def handle_event("change_basics", params, socket) do
    {:ok, editor} = PlanEditor.change_basics(socket.assigns.editor, params)

    socket =
      socket
      |> put_editor(editor)
      |> assign_form_from_editor()
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

    editor = %{
      socket.assigns.editor
      | input: %{input | block_pattern: pattern ++ [1], manual_structure?: true}
    }

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
      with {:ok, index} <- parse_non_negative_index(index),
           true <- length(pattern) > 1 do
        pattern
        |> List.delete_at(index)
        |> case do
          [] -> [1]
          pattern -> pattern
        end
      else
        _ -> pattern
      end

    editor = %{
      socket.assigns.editor
      | input: %{input | block_pattern: next_pattern, manual_structure?: true}
    }

    socket =
      socket
      |> put_editor(editor)
      |> regenerate()
      |> assign_derived()

    {:noreply, socket}
  end

  def handle_event("add_rest", _params, socket), do: open_rest_prompt(socket)

  def handle_event("open_rest_prompt", _params, socket), do: open_rest_prompt(socket)

  def handle_event("close_rest_prompt", _params, socket),
    do: {:noreply, assign(socket, :rest_prompt, nil)}

  def handle_event("insert_prompted_rest", %{"rest" => rest_params}, socket) do
    form_plan = socket.assigns.editor.form_plan
    rest_sec = parse_positive_integer_or(Map.get(rest_params, "rest_sec"), 30)
    edge_index = parse_non_negative_integer_or(Map.get(rest_params, "edge_index"), 1)

    steps =
      form_plan.steps
      |> ensure_block_run_steps(form_plan.blocks)
      |> insert_rest_step(edge_index, rest_sec)

    form_plan =
      form_plan
      |> Map.put(:steps, steps)
      |> recalibrate_plan_to_target(socket.assigns.editor.input.target_duration_min * 60)

    editor = %{
      socket.assigns.editor
      | form_plan: form_plan,
        manual_edit?: true,
        open_block_menu: nil
    }

    attrs = form_plan |> plan_to_attrs() |> Map.put("steps", steps_to_attrs(steps))
    base_plan = socket.assigns.plan || form_plan
    changeset = change_form_plan(base_plan, attrs) |> Map.put(:action, :validate)

    socket =
      socket
      |> put_editor(editor)
      |> assign(:form, to_form(changeset))
      |> assign(:rest_prompt, nil)
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
      | input: %{
          input
          | additional_rests:
              upsert_editor_rest(
                input.additional_rests,
                length(input.additional_rests || []),
                rest
              )
        }
    }

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
        | input: %{
            input
            | additional_rests:
                upsert_editor_rest(
                  input.additional_rests,
                  length(input.additional_rests || []),
                  rest
                )
          }
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
           |> assign(:timeline_error, nil)
           |> assign_derived()}

        {:error, message} ->
          {:noreply, assign(socket, :timeline_error, message)}
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
        editor = %{editor | open_block_menu: nil}
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
      |> Workouts.change_plan(editor_form_attrs(socket.assigns.editor, params))
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

      save_plan(
        socket,
        socket.assigns.live_action,
        editor_save_attrs(socket.assigns.editor, submitted_params)
      )
    else
      {:noreply, assign(socket, :solver_error, "Fix prescription before saving")}
    end
  end

  def handle_event("start_workout", params, socket) do
    if feasible_prescription?(socket.assigns.derived) do
      submitted_params = Map.get(params, "workout_plan", %{})

      start_plan(
        socket,
        socket.assigns.live_action,
        editor_save_attrs(socket.assigns.editor, submitted_params)
      )
    else
      {:noreply, assign(socket, :solver_error, "Fix workout before starting")}
    end
  end

  def handle_event("duplicate_plan", _, %{assigns: %{live_action: :edit, plan: plan}} = socket) do
    case Workouts.duplicate_plan(plan) do
      {:ok, copy} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workout copied.")
         |> push_navigate(to: ~p"/workouts/#{copy.id}/edit")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not copy workout.")}
    end
  end

  def handle_event("delete_plan", _, %{assigns: %{live_action: :edit, plan: plan}} = socket) do
    case Workouts.delete_plan(plan) do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workout deleted.")
         |> push_navigate(to: ~p"/workouts")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not delete workout.")}
    end
  end

  defp open_rest_prompt(socket) do
    form_plan = socket.assigns.editor.form_plan

    edges =
      form_plan.steps
      |> ensure_block_run_steps(form_plan.blocks)
      |> rest_placement_edges()

    default_edge =
      edges
      |> Enum.find(& &1.default?)
      |> case do
        %{edge_index: edge_index} ->
          edge_index

        _missing ->
          edges
          |> List.first()
          |> case do
            %{edge_index: edge_index} -> edge_index
            _none -> nil
          end
      end

    {:noreply, assign(socket, :rest_prompt, %{rest_sec: 30, edge_index: default_edge})}
  end

  defp validate_editor_form(socket, editor) do
    base_plan = editor.plan || %WorkoutPlan{}

    changeset =
      base_plan
      |> Workouts.change_plan(editor_form_attrs(editor))
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

  defp start_plan(socket, :new, params) do
    case Workouts.create_plan(socket.assigns.current_user, params) do
      {:ok, plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workout ready.")
         |> push_navigate(to: ~p"/session/#{plan.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(:form, to_form(changeset)) |> assign_derived()}

      {:error, %CompileError{} = error} ->
        {:noreply, assign(socket, :solver_error, error.message)}
    end
  end

  defp start_plan(socket, :edit, params) do
    case Workouts.update_plan(socket.assigns.plan, params) do
      {:ok, plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workout ready.")
         |> push_navigate(to: ~p"/session/#{plan.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(:form, to_form(changeset)) |> assign_derived()}

      {:error, %CompileError{} = error} ->
        {:noreply, assign(socket, :solver_error, error.message)}
    end
  end

  defp save_plan(socket, :new, params) do
    case Workouts.create_plan(socket.assigns.current_user, params) do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workout created.")
         |> push_navigate(to: ~p"/workouts")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> assign_derived()}

      {:error, %CompileError{} = error} ->
        {:noreply, assign(socket, :solver_error, error.message)}
    end
  end

  defp save_plan(socket, :edit, params) do
    case Workouts.update_plan(socket.assigns.plan, params) do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workout saved.")
         |> push_navigate(to: ~p"/workouts")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> assign_derived()}

      {:error, %CompileError{} = error} ->
        {:noreply, assign(socket, :solver_error, error.message)}
    end
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

  defp structure_pattern(%{block_pattern: pattern}) when is_list(pattern) and pattern != [],
    do: pattern

  defp structure_pattern(plan_input), do: default_pattern(plan_input)

  defp structure_summary(%{manual_structure?: true, burpee_count_target: target} = plan_input) do
    pattern = structure_pattern(plan_input)
    reps_per_block = Enum.sum(pattern)

    block_text =
      cond do
        reps_per_block <= 0 ->
          "Choose a pattern"

        rem(target, reps_per_block) == 0 ->
          "#{div(target, reps_per_block)} #{plural(div(target, reps_per_block), "block")} for #{target} reps"

        true ->
          "#{div(target, reps_per_block)} full #{plural(div(target, reps_per_block), "block")} + #{rem(target, reps_per_block)} reps"
      end

    "#{reps_per_block} reps per block · #{block_text}"
  end

  defp structure_summary(_plan_input), do: "Planner chooses readable blocks."

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  attr(:plan, :any, required: true)
  attr(:editor, :any, required: true)
  attr(:form, :any, required: true)
  attr(:expanded_blocks, :any, required: true)
  attr(:expanded_timeline_row, :any, required: true)
  attr(:open_block_menu, :any, required: true)
  attr(:plan_input, :map, required: true)
  attr(:manual_edit, :boolean, required: true)
  attr(:derived, :any, required: true)
  attr(:solver_error, :any, required: true)
  attr(:timeline_error, :any, required: true)
  attr(:solver_solution, :any, required: true)
  attr(:live_action, :atom, required: true)
  attr(:level, :atom, required: true)
  attr(:creator_phase, :atom, default: :editor)
  attr(:creator_advanced?, :boolean, default: false)
  attr(:selected_block_index, :integer, default: nil)
  attr(:locked_block_indexes, :any, default: MapSet.new())
  attr(:rest_prompt, :map, default: nil)

  defp plan_solution_card(assigns) do
    form_plan = assigns.editor.form_plan || Ecto.Changeset.apply_changes(assigns.form.source)
    block_rows = Presentation.block_rows(form_plan, assigns.locked_block_indexes)

    contract =
      form_plan
      |> Presentation.contract(assigns.derived)
      |> Map.merge(%{
        block_rows: block_rows,
        structure_rows: Presentation.structure_rows(form_plan, block_rows),
        structure_map: Presentation.structure_map(block_rows),
        structure_groups: Presentation.structure_groups(block_rows)
      })

    steps = loaded_steps(form_plan.steps)
    block_time_ranges = block_time_ranges(form_plan.blocks, assigns.plan_input)

    timeline_rows =
      prescription_timeline(
        form_plan.blocks,
        steps,
        block_time_ranges,
        assigns.derived,
        assigns.plan_input
      )

    timeline_rest_edges = timeline_rest_edges(assigns.plan_input, assigns.level, timeline_rows)

    assigns =
      assigns
      |> assign(:contract, contract)
      |> assign(:block_time_ranges, block_time_ranges)
      |> assign(
        :plan_feedback,
        plan_feedback(
          assigns.timeline_error,
          assigns.solver_error,
          assigns.derived,
          assigns.plan_input
        )
      )
      |> assign(:presentation_outline, PlanPresentation.outline(form_plan))
      |> assign(:pattern_summary, pattern_summary(assigns.plan_input, assigns.derived))
      |> assign(:start_available?, feasible_prescription?(assigns.derived))
      |> assign(
        :prescription_blocked?,
        prescription_blocked?(assigns.solver_error, assigns.derived)
      )
      |> assign(:timeline_rows, timeline_rows)
      |> assign(:timeline_rest_edges, timeline_rest_edges)
      |> assign(
        :rest_placement_edges,
        rest_placement_edges(ensure_block_run_steps(steps, form_plan.blocks))
      )

    assigns = assign(assigns, :selected_timeline_row, selected_timeline_row(assigns))

    plan_solution_card_template(assigns)
  end

  defp selected_timeline_row(%{expanded_timeline_row: row_index, timeline_rows: rows})
       when is_integer(row_index) do
    Enum.at(rows, row_index)
  end

  defp selected_timeline_row(_assigns), do: nil

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

  defp prescription_blocked?(solver_error, nil), do: is_binary(solver_error)

  defp prescription_blocked?(solver_error, %{both_ok: both_ok}),
    do: is_binary(solver_error) and not both_ok

  defp prescription_blocked?(_solver_error, _derived), do: false

  defp plan_feedback(timeline_error, _solver_error, _derived, _plan_input)
       when is_binary(timeline_error) do
    %{
      title: "Rest placement needs attention",
      message: timeline_error,
      actions: [
        "Move the rest closer to a set boundary",
        "Shorten the rest",
        "Increase the duration"
      ]
    }
  end

  defp plan_feedback(nil, solver_error, derived, plan_input),
    do: Presentation.plan_feedback(solver_error, derived, plan_input)

  defp plan_feedback(_timeline_error, _solver_error, _derived, _plan_input), do: nil

  attr(:plan_input, :map, required: true)
  attr(:live_action, :atom, required: true)
  attr(:plan, :any, required: true)

  defp plan_editor_header(assigns) do
    ~H"""
    <.qs_surface class="bg-[var(--session-surface)]/55 px-5 py-5">
      <div class="flex items-start justify-between gap-4">
        <form id="workout-name-form" phx-change="change_basics" class="min-w-0 flex-1 space-y-2">
          <label class="text-sm font-medium text-[var(--session-muted)]">
            {if @live_action == :new, do: "Workout name", else: "Custom workout"}
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
            do: "bg-[var(--session-ink)] text-[var(--session-bg)]",
            else:
              "text-[var(--session-muted)] hover:bg-[var(--session-bg)] hover:text-[var(--session-ink)]"
          )
        ]}
      >
        Six-count
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
  attr(:compact, :boolean, default: false)

  defp plan_pacing_controls(assigns) do
    ~H"""
    <form id="plan-pacing-controls" phx-change="change_basics" class="bg-[var(--session-surface)]/40">
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
          Unbroken sets
        </button>
      </div>
      <%= if @plan_input.pacing_style == :unbroken and not @compact do %>
        <div class="flex items-baseline justify-between border-t border-[var(--session-border)] px-6 py-5">
          <div class="space-y-1">
            <p class="text-sm font-medium text-[var(--session-muted)]">Max per set</p>
            <div class="flex items-baseline gap-1.5">
              <input
                type="number"
                name="reps_per_set"
                min="1"
                max={@plan_input.burpee_count_target}
                value={@plan_input.reps_per_set}
                class="w-20 bg-transparent text-3xl font-bold leading-none tabular-nums text-[var(--session-ink)] focus:outline-none"
              />
              <span class="text-sm text-[var(--session-muted)]">reps</span>
            </div>
          </div>
          <span class="text-sm tabular-nums text-[var(--session-muted)]">
            {@plan_input.reps_per_set || 1} reps max
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

  defp outline_range_label(%{from_set: from, to_set: to}) when from == to, do: "Set #{from}"
  defp outline_range_label(%{from_set: from, to_set: to}), do: "Sets #{from}–#{to}"

  defp outline_row_note(%{recovery_sec: 0}, _block), do: "Finish"

  defp outline_row_note(%{recovery_sec: recovery}, %{default_recovery_sec: recovery}),
    do: "Normal recovery"

  defp outline_row_note(_row, _block), do: "Reset recovery"

  defp outline_rhythm_label(:unbroken), do: "Unbroken"
  defp outline_rhythm_label(:even), do: "Cadenced"
  defp outline_rhythm_label(style), do: Phoenix.Naming.humanize(to_string(style))

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

  defp block_duration(nil), do: 0.0

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

  defp timeline_rest_edges(plan_input, level, rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {row, row_index}, edges ->
      next_row = Enum.at(rows, row_index + 1)
      Map.put(edges, row_index, timeline_rest_edge_available?(plan_input, level, row, next_row))
    end)
  end

  defp timeline_rest_edge_available?(_plan_input, _level, %{kind: :finish}, _next_row), do: false

  defp timeline_rest_edge_available?(plan_input, level, row, next_row) do
    target_min = timeline_edge_target_min(row, next_row)
    rest = %{target_min: target_min, rest_sec: 30}

    solver_input = %PlanSolverInput{
      name: plan_input.name,
      burpee_type: plan_input.burpee_type,
      target_duration_min: plan_input.target_duration_min,
      burpee_count_target: plan_input.burpee_count_target,
      pacing_style: plan_input.pacing_style,
      level: level,
      reps_per_set: plan_input.reps_per_set,
      additional_rests: plan_input.additional_rests ++ [rest],
      sec_per_burpee_override: plan_input.sec_per_burpee_override,
      block_pattern: plan_input.block_pattern
    }

    match?({:ok, _solution}, PlanSolver.solve(solver_input))
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
