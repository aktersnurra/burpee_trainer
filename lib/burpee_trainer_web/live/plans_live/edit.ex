defmodule BurpeeTrainerWeb.PlansLive.Edit do
  @moduledoc """
  Plan editor.

  Targets at the top — type, duration, reps, pacing style. The solver
  turns them into an editable structure of work blocks (`N×[reps, …]`)
  and rests. Structure edits re-balance pace and recovery against the
  targets; anything that blocks a save is reported with one-tap fixes.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Levels, PlanEditor, PlanSolver, Workouts}
  alias BurpeeTrainer.PlanEditor.Segments
  alias BurpeeTrainer.Workouts.WorkoutPlan
  alias BurpeeTrainerWeb.Fmt

  embed_templates("edit/*")

  @impl true
  def mount(params, _session, socket) do
    sessions = Workouts.list_sessions(socket.assigns.current_user)
    level = Levels.current_level(sessions)

    {:ok,
     socket
     |> assign(:level, level)
     |> assign(:segments, [])
     |> assign(:custom?, false)
     |> assign(:solver_error, nil)
     |> assign(:solver_fixes, [])
     |> load_plan(params)
     |> assign_balance()}
  end

  defp load_plan(socket, %{"id" => id}) do
    plan = Workouts.get_plan!(socket.assigns.current_user, String.to_integer(id))
    {:ok, editor} = PlanEditor.from_plan(plan, socket.assigns.level)

    socket
    |> assign(:plan, plan)
    |> assign(:editor, editor)
    |> assign(:segments, Segments.from_plan(plan))
    |> assign(:custom?, true)
    |> assign(:page_title, "Edit plan")
  end

  defp load_plan(socket, params) do
    {:ok, editor} = PlanEditor.new(socket.assigns.level, params)

    socket
    |> assign(:plan, nil)
    |> assign(:editor, editor)
    |> assign(:page_title, "New plan")
    |> regenerate()
  end

  # ---------------------------------------------------------------------------
  # State helpers
  # ---------------------------------------------------------------------------

  defp regenerate(socket) do
    editor = sync_rests(socket)
    {:ok, editor} = PlanEditor.regenerate(editor)

    case editor.solver_solution do
      nil ->
        socket
        |> assign(:editor, editor)
        |> assign(:custom?, false)
        |> assign(:solver_error, editor.solver_error)
        |> assign(:solver_fixes, Segments.target_fixes(editor.input, editor.level))

      solution ->
        socket
        |> assign(:editor, editor)
        |> assign(:segments, Segments.from_solution(solution))
        |> assign(:custom?, false)
        |> assign(:solver_error, nil)
        |> assign(:solver_fixes, [])
    end
  end

  # Carry user-placed rests over to the solver input before regenerating.
  defp sync_rests(socket) do
    editor = socket.assigns.editor
    balance = socket.assigns[:balance]
    segments = socket.assigns.segments

    rests =
      if balance do
        {rests, _elapsed} =
          Enum.reduce(segments, {[], 0.0}, fn segment, {rests, elapsed} ->
            case segment do
              %{kind: :work} = work ->
                duration =
                  work.repeat *
                    (Enum.sum(work.pattern) * balance.pace +
                       length(work.pattern) * balance.recovery_sec)

                {rests, elapsed + duration}

              %{kind: :rest, rest_sec: rest_sec} ->
                rest = %{rest_sec: rest_sec, target_min: max(round(elapsed / 60), 1)}
                {rests ++ [rest], elapsed + rest_sec}
            end
          end)

        rests
      else
        editor.input.additional_rests
      end

    %{editor | input: %{editor.input | additional_rests: rests}}
  end

  defp assign_balance(socket) do
    editor = socket.assigns.editor
    balance = Segments.balance(socket.assigns.segments, editor.input, editor.level)
    assign(socket, :balance, balance)
  end

  # Structure edits mark the plan custom and re-balance.
  defp put_segments(socket, segments) do
    socket
    |> assign(:segments, segments)
    |> assign(:custom?, true)
    |> assign(:solver_error, nil)
    |> assign(:solver_fixes, [])
    |> assign_balance()
  end

  # Target edits re-run the solver unless the structure is custom,
  # in which case the structure is kept and only re-balanced.
  defp put_editor(socket, editor) do
    socket = assign(socket, :editor, editor)

    if socket.assigns.custom? do
      assign_balance(socket)
    else
      socket |> regenerate() |> assign_balance()
    end
  end

  # ---------------------------------------------------------------------------
  # Events — targets
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("change_basics", params, socket) do
    {:ok, editor} = PlanEditor.change_basics(socket.assigns.editor, params)
    {:noreply, put_editor(socket, editor)}
  end

  def handle_event("pick_type", %{"type" => type}, socket) do
    case PlanEditor.pick_type(socket.assigns.editor, type) do
      {:ok, editor} -> {:noreply, put_editor(socket, editor)}
      {:error, _reason, _editor} -> {:noreply, socket}
    end
  end

  def handle_event("pick_pacing", %{"style" => style}, socket) do
    case PlanEditor.pick_pacing(socket.assigns.editor, style) do
      {:ok, editor} -> {:noreply, put_editor(socket, editor)}
      {:error, _reason, _editor} -> {:noreply, socket}
    end
  end

  def handle_event("set_pace_override", %{"pace" => pace}, socket) do
    {:ok, editor} = PlanEditor.set_pace_override(socket.assigns.editor, pace)
    {:noreply, put_editor(socket, editor)}
  end

  def handle_event("regenerate", _params, socket) do
    {:noreply, socket |> regenerate() |> assign_balance()}
  end

  def handle_event("apply_fix", %{"kind" => "regenerate"}, socket) do
    {:noreply, socket |> regenerate() |> assign_balance()}
  end

  def handle_event("apply_fix", %{"kind" => kind, "value" => value}, socket)
      when kind in ["duration", "reps"] do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 ->
        editor = socket.assigns.editor

        input =
          case kind do
            "duration" -> %{editor.input | target_duration_min: parsed}
            "reps" -> %{editor.input | burpee_count_target: parsed}
          end

        {:noreply, put_editor(socket, %{editor | input: input})}

      _ ->
        {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Events — structure
  # ---------------------------------------------------------------------------

  def handle_event("update_segment", %{"index" => index} = params, socket) do
    index = String.to_integer(index)
    repeat = parse_positive(Map.get(params, "repeat"))

    set_reps =
      params
      |> Map.get("sets", %{})
      |> Enum.reduce(%{}, fn {set_index, value}, acc ->
        case parse_positive(value) do
          nil -> acc
          reps -> Map.put(acc, String.to_integer(set_index), reps)
        end
      end)

    segments = Segments.update_work(socket.assigns.segments, index, repeat, set_reps)
    {:noreply, put_segments(socket, segments)}
  end

  def handle_event("update_rest", %{"index" => index} = params, socket) do
    index = String.to_integer(index)

    case parse_positive(Map.get(params, "rest_sec")) do
      nil ->
        {:noreply, socket}

      rest_sec ->
        segments = Segments.update_rest(socket.assigns.segments, index, rest_sec)
        {:noreply, put_segments(socket, segments)}
    end
  end

  def handle_event("add_set", %{"index" => index}, socket) do
    segments = Segments.add_set(socket.assigns.segments, String.to_integer(index))
    {:noreply, put_segments(socket, segments)}
  end

  def handle_event("remove_set", %{"index" => index, "set" => set_index}, socket) do
    segments =
      Segments.remove_set(
        socket.assigns.segments,
        String.to_integer(index),
        String.to_integer(set_index)
      )

    {:noreply, put_segments(socket, segments)}
  end

  def handle_event("split_segment", %{"index" => index}, socket) do
    segments = Segments.split_work(socket.assigns.segments, String.to_integer(index))
    {:noreply, put_segments(socket, segments)}
  end

  def handle_event("remove_segment", %{"index" => index}, socket) do
    segments = Segments.remove_at(socket.assigns.segments, String.to_integer(index))
    {:noreply, put_segments(socket, segments)}
  end

  def handle_event("insert_block", %{"index" => index}, socket) do
    input = socket.assigns.editor.input

    default_reps =
      input.reps_per_set || PlanSolver.default_reps_per_set(input.burpee_type)

    segments =
      Segments.insert_work(socket.assigns.segments, String.to_integer(index), default_reps)

    {:noreply, put_segments(socket, segments)}
  end

  def handle_event("insert_rest", %{"index" => index}, socket) do
    segments = Segments.insert_rest(socket.assigns.segments, String.to_integer(index))
    {:noreply, put_segments(socket, segments)}
  end

  # ---------------------------------------------------------------------------
  # Events — persistence
  # ---------------------------------------------------------------------------

  def handle_event("save", _params, socket) do
    %{balance: balance, segments: segments, editor: editor} = socket.assigns

    if balance.ok? do
      attrs = Segments.to_plan_attrs(segments, editor.input, balance)
      save_plan(socket, socket.assigns.live_action, attrs)
    else
      {:noreply, socket}
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

  defp save_plan(socket, :new, attrs) do
    case Workouts.create_plan(socket.assigns.current_user, attrs) do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plan created.")
         |> push_navigate(to: ~p"/workouts")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save the plan.")}
    end
  end

  defp save_plan(socket, :edit, attrs) do
    case Workouts.update_plan(socket.assigns.plan, attrs) do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plan saved.")
         |> push_navigate(to: ~p"/workouts")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save the plan.")}
    end
  end

  defp parse_positive(value) do
    case Integer.parse(to_string(value || "")) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # View helpers
  # ---------------------------------------------------------------------------

  defp work_duration_sec(%{kind: :work} = segment, balance) do
    segment.repeat *
      (Enum.sum(segment.pattern) * balance.pace +
         length(segment.pattern) * balance.recovery_sec)
  end

  defp segment_reps(%{kind: :work} = segment), do: segment.repeat * Enum.sum(segment.pattern)

  defp format_pace(pace) when is_float(pace), do: :erlang.float_to_binary(pace, decimals: 1)
  defp format_pace(pace), do: to_string(pace)

  defp stats_line(balance, pacing_style) do
    recovery =
      if pacing_style == :unbroken and balance.set_count > 1 do
        " · #{balance.recovery_sec}s recovery"
      else
        ""
      end

    "#{balance.reps} reps · #{Fmt.duration_sec(round(balance.duration_sec))} · " <>
      "#{format_pace(balance.pace)}s/rep#{recovery}"
  end

  # ---------------------------------------------------------------------------
  # Components
  # ---------------------------------------------------------------------------

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
      class="rounded-2xl border border-[var(--session-border)] bg-[var(--session-track)]/25 px-5 py-4"
    >
      <p class="text-[10px] font-medium uppercase tracking-[0.18em] text-[var(--session-muted)]">
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

  attr(:active, :boolean, required: true)
  attr(:rest, :global, include: ~w(phx-click phx-value-type phx-value-style id))
  slot(:inner_block, required: true)

  defp toggle_button(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "flex-1 py-3 text-sm font-medium tracking-wide transition first:rounded-l-2xl last:rounded-r-2xl",
        if(@active,
          do: "bg-[var(--session-ink)] text-[var(--session-bg)]",
          else:
            "text-[var(--session-muted)] hover:bg-[var(--session-bg)] hover:text-[var(--session-ink)]"
        )
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr(:fixes, :list, required: true)

  defp fix_buttons(assigns) do
    ~H"""
    <div :if={@fixes != []} class="flex flex-wrap gap-2">
      <button
        :for={fix <- @fixes}
        type="button"
        phx-click="apply_fix"
        phx-value-kind={fix.kind}
        phx-value-value={fix.value}
        data-fix={fix.kind}
        class="rounded-xl border border-[var(--session-border)] bg-[var(--session-surface)] px-3 py-2 text-xs font-medium text-[var(--session-ink)] transition hover:border-[var(--session-ink)]"
      >
        {fix.label}
      </button>
    </div>
    """
  end

  attr(:index, :integer, required: true)

  defp insert_pills(assigns) do
    ~H"""
    <div class="flex items-center gap-2 py-0.5">
      <span class="h-px flex-1 bg-[var(--session-border)]" aria-hidden="true" />
      <button
        type="button"
        phx-click="insert_block"
        phx-value-index={@index}
        data-insert-block={@index}
        class="rounded-full border border-[var(--session-border)] px-2.5 py-1 text-[11px] font-medium text-[var(--session-muted)] transition hover:text-[var(--session-ink)]"
      >
        + Block
      </button>
      <button
        type="button"
        phx-click="insert_rest"
        phx-value-index={@index}
        data-insert-rest={@index}
        class="rounded-full border border-[var(--session-border)] px-2.5 py-1 text-[11px] font-medium text-[var(--session-muted)] transition hover:text-[var(--session-ink)]"
      >
        + Rest
      </button>
      <span class="h-px flex-1 bg-[var(--session-border)]" aria-hidden="true" />
    </div>
    """
  end
end
