defmodule BurpeeTrainerWeb.PlansLive.Index do
  @moduledoc """
  Plan list with a 6-step Quick Generate wizard backed by `PlanWizard`.
  Each saved-plan card shows totals and links to edit / run / duplicate / delete.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Planner, Workouts}
  alias BurpeeTrainer.PlanWizard
  alias BurpeeTrainer.PlanWizard.WizardInput
  alias BurpeeTrainerWeb.Fmt

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_plans()
     |> assign(:wizard_open, false)
     |> assign(:wizard_step, 1)
     |> assign(:wizard_input, wizard_default_input())
     |> assign(:wizard_error, nil)}
  end

  defp wizard_default_input do
    %{
      duration_min: 20,
      burpee_type: nil,
      burpee_count: 100,
      sec_per_burpee: 5.0,
      pacing_style: nil,
      extra_rest_enabled: false,
      extra_rest_at_min: 10,
      extra_rest_sec: 30
    }
  end

  # ---------------------------------------------------------------------------
  # Plan list events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("duplicate", %{"id" => id}, socket) do
    plan = Workouts.get_plan!(socket.assigns.current_user, String.to_integer(id))

    case Workouts.duplicate_plan(plan) do
      {:ok, _copy} ->
        {:noreply, socket |> put_flash(:info, "Plan duplicated.") |> assign_plans()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not duplicate plan.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    plan = Workouts.get_plan!(socket.assigns.current_user, String.to_integer(id))
    {:ok, _} = Workouts.delete_plan(plan)
    {:noreply, socket |> put_flash(:info, "Plan deleted.") |> assign_plans()}
  end

  # ---------------------------------------------------------------------------
  # Wizard events
  # ---------------------------------------------------------------------------

  def handle_event("open_wizard", _, socket) do
    {:noreply,
     socket
     |> assign(:wizard_open, true)
     |> assign(:wizard_step, 1)
     |> assign(:wizard_input, wizard_default_input())
     |> assign(:wizard_error, nil)}
  end

  def handle_event("close_wizard", _, socket) do
    {:noreply, assign(socket, :wizard_open, false)}
  end

  def handle_event("wizard_back", _, socket) do
    step = max(1, socket.assigns.wizard_step - 1)
    {:noreply, assign(socket, wizard_step: step, wizard_error: nil)}
  end

  # Step 1: duration
  def handle_event("wizard_next", %{"duration_min" => raw}, socket) do
    case Integer.parse(raw) do
      {n, ""} when n in 5..60 ->
        {:noreply,
         socket
         |> update(:wizard_input, &Map.put(&1, :duration_min, n))
         |> assign(:wizard_step, 2)
         |> assign(:wizard_error, nil)}

      _ ->
        {:noreply, assign(socket, :wizard_error, "Enter a duration between 5 and 60 minutes.")}
    end
  end

  # Step 2: burpee type (auto-advance)
  def handle_event("wizard_pick_type", %{"type" => type}, socket)
      when type in ["six_count", "navy_seal"] do
    {:noreply,
     socket
     |> update(:wizard_input, &Map.put(&1, :burpee_type, String.to_atom(type)))
     |> assign(:wizard_step, 3)
     |> assign(:wizard_error, nil)}
  end

  # Step 3: burpee count
  def handle_event("wizard_next", %{"burpee_count" => raw}, socket) do
    duration_sec = socket.assigns.wizard_input.duration_min * 60
    sec_per = socket.assigns.wizard_input.sec_per_burpee

    case Integer.parse(raw) do
      {n, ""} when n > 0 ->
        work = n * sec_per
        error = if work > duration_sec, do: "Work time (#{round(work)}s) exceeds duration (#{duration_sec}s). Reduce reps or increase time.", else: nil
        if error do
          {:noreply, assign(socket, :wizard_error, error)}
        else
          {:noreply,
           socket
           |> update(:wizard_input, &Map.put(&1, :burpee_count, n))
           |> assign(:wizard_step, 4)
           |> assign(:wizard_error, nil)}
        end

      _ ->
        {:noreply, assign(socket, :wizard_error, "Enter a positive number of burpees.")}
    end
  end

  # Step 4: sec/rep adjust
  def handle_event("wizard_adjust_pace", %{"delta" => delta_str}, socket) do
    delta = String.to_float(delta_str)
    current = socket.assigns.wizard_input.sec_per_burpee
    new_val = max(1.0, Float.round(current + delta, 1))
    {:noreply, update(socket, :wizard_input, &Map.put(&1, :sec_per_burpee, new_val))}
  end

  def handle_event("wizard_next", %{"confirm_pace" => _}, socket) do
    inp = socket.assigns.wizard_input
    work = inp.burpee_count * inp.sec_per_burpee
    duration_sec = inp.duration_min * 60

    if work > duration_sec do
      {:noreply, assign(socket, :wizard_error, "Work time (#{round(work)}s) exceeds duration. Reduce pace or burpee count.")}
    else
      {:noreply, assign(socket, wizard_step: 5, wizard_error: nil)}
    end
  end

  # Step 5: pacing style (auto-advance)
  def handle_event("wizard_pick_pacing", %{"style" => style}, socket)
      when style in ["even", "unbroken"] do
    {:noreply,
     socket
     |> update(:wizard_input, &Map.put(&1, :pacing_style, String.to_atom(style)))
     |> assign(:wizard_step, 6)
     |> assign(:wizard_error, nil)}
  end

  # Step 6: extra rest toggle
  def handle_event("wizard_toggle_extra_rest", _, socket) do
    {:noreply, update(socket, :wizard_input, fn inp ->
      Map.put(inp, :extra_rest_enabled, !inp.extra_rest_enabled)
    end)}
  end

  def handle_event("wizard_update_extra", %{"field" => field, "value" => raw}, socket)
      when field in ["extra_rest_at_min", "extra_rest_sec"] do
    case Integer.parse(raw) do
      {n, ""} when n > 0 ->
        key = String.to_atom(field)
        {:noreply, update(socket, :wizard_input, &Map.put(&1, key, n))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("wizard_generate", _, socket) do
    inp = socket.assigns.wizard_input

    extra_rest =
      if inp.extra_rest_enabled,
        do: %{at_sec: inp.extra_rest_at_min * 60, rest_sec: inp.extra_rest_sec},
        else: nil

    wizard_input = %WizardInput{
      duration_sec_total: inp.duration_min * 60,
      burpee_type: inp.burpee_type,
      burpee_count_total: inp.burpee_count,
      sec_per_burpee: inp.sec_per_burpee * 1.0,
      pacing_style: inp.pacing_style,
      extra_rest: extra_rest
    }

    case PlanWizard.generate(wizard_input) do
      {:ok, plan} ->
        case Workouts.save_generated_plan(socket.assigns.current_user, plan) do
          {:ok, saved} ->
            {:noreply, push_navigate(socket, to: ~p"/plans/#{saved.id}/edit")}

          {:error, _cs} ->
            {:noreply, assign(socket, :wizard_error, "Could not save plan.")}
        end

      {:error, reasons} ->
        {:noreply, assign(socket, :wizard_error, Enum.join(reasons, "; "))}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp assign_plans(socket) do
    plans = Workouts.list_plans(socket.assigns.current_user)
    cards = Enum.map(plans, fn plan -> {plan, Planner.summary(plan)} end)
    assign(socket, :cards, cards)
  end

  defp wizard_pace_summary(inp) do
    work = inp.burpee_count * inp.sec_per_burpee
    rest = max(0, inp.duration_min * 60 - work)
    "Work #{Fmt.duration_sec(round(work))} · Rest #{Fmt.duration_sec(round(rest))}"
  end

  defp wizard_rate_hint(inp) do
    if inp.duration_min > 0,
      do: "≈ #{Float.round(inp.burpee_count / inp.duration_min, 1)} burpees/min",
      else: ""
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_level={@current_level}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Plans</h1>
            <p class="text-sm text-base-content/60">Workouts you've built, ready to run.</p>
          </div>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="open_wizard"
              class="rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
            >
              Quick Generate
            </button>
            <.link
              navigate={~p"/plans/new"}
              class="rounded-md border border-base-300 px-4 py-2 text-sm hover:bg-base-200 transition"
            >
              Build Manual
            </.link>
          </div>
        </div>

        <%= if @wizard_open do %>
          <.wizard_panel
            step={@wizard_step}
            input={@wizard_input}
            error={@wizard_error}
          />
        <% end %>

        <%= if @cards == [] do %>
          <div class="rounded-lg border border-dashed border-base-300 p-12 text-center space-y-2">
            <p class="text-base-content/70">No plans yet.</p>
            <p class="text-sm text-base-content/50">Use Quick Generate or Build Manual above.</p>
          </div>
        <% else %>
          <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <%= for {plan, summary} <- @cards do %>
              <div class="rounded-lg border border-base-300 bg-base-100 p-5 space-y-4 flex flex-col">
                <div class="space-y-1">
                  <h2 class="text-lg font-semibold tracking-tight">{plan.name}</h2>
                  <div class="inline-flex items-center rounded-full bg-base-200 px-2 py-0.5 text-xs text-base-content/70">
                    {Fmt.burpee_type(plan.burpee_type)}
                  </div>
                </div>

                <dl class="grid grid-cols-2 gap-2 text-sm">
                  <div>
                    <dt class="text-base-content/50 text-xs uppercase tracking-wide">Burpees</dt>
                    <dd class="font-semibold">{summary.burpee_count_total}</dd>
                  </div>
                  <div>
                    <dt class="text-base-content/50 text-xs uppercase tracking-wide">Duration</dt>
                    <dd class="font-semibold">{Fmt.duration_sec(summary.duration_sec_total)}</dd>
                  </div>
                </dl>

                <div class="flex-1" />

                <div class="flex flex-wrap gap-2 pt-2">
                  <.link
                    navigate={~p"/session/#{plan.id}"}
                    class="flex-1 text-center rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
                  >
                    Run
                  </.link>
                  <.link
                    navigate={~p"/plans/#{plan.id}/edit"}
                    class="flex-1 text-center rounded-md border border-base-300 px-3 py-1.5 text-sm hover:bg-base-200 transition"
                  >
                    Edit
                  </.link>
                  <button
                    type="button"
                    phx-click="duplicate"
                    phx-value-id={plan.id}
                    class="rounded-md border border-base-300 px-3 py-1.5 text-sm hover:bg-base-200 transition"
                  >
                    Duplicate
                  </button>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={plan.id}
                    data-confirm={"Delete '#{plan.name}'? This cannot be undone."}
                    class="rounded-md border border-error/40 px-3 py-1.5 text-sm text-error hover:bg-error/10 transition"
                  >
                    Delete
                  </button>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Wizard component
  # ---------------------------------------------------------------------------

  attr :step, :integer, required: true
  attr :input, :map, required: true
  attr :error, :string, default: nil

  defp wizard_panel(assigns) do
    ~H"""
    <section class="rounded-lg border border-primary/30 bg-base-100 p-6 space-y-5">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-lg font-semibold tracking-tight">Quick Generate</h2>
          <p class="text-xs text-base-content/50">Step {@step} of 6</p>
        </div>
        <button
          type="button"
          phx-click="close_wizard"
          class="text-base-content/40 hover:text-base-content text-xl leading-none"
        >
          ×
        </button>
      </div>

      <%= if @error do %>
        <p class="rounded-md bg-error/10 border border-error/30 px-3 py-2 text-sm text-error">
          {@error}
        </p>
      <% end %>

      <%= case @step do %>
        <% 1 -> %>
          <.wizard_step_duration input={@input} />
        <% 2 -> %>
          <.wizard_step_type input={@input} />
        <% 3 -> %>
          <.wizard_step_count input={@input} />
        <% 4 -> %>
          <.wizard_step_pace input={@input} />
        <% 5 -> %>
          <.wizard_step_pacing input={@input} />
        <% 6 -> %>
          <.wizard_step_extra input={@input} />
      <% end %>
    </section>
    """
  end

  # Step 1 — Total time
  defp wizard_step_duration(assigns) do
    ~H"""
    <div class="space-y-4">
      <div>
        <p class="text-base font-medium">Total workout time</p>
        <p class="text-sm text-base-content/60">How long should the session be?</p>
      </div>
      <form phx-submit="wizard_next" class="space-y-4">
        <div class="flex items-center gap-4">
          <input
            type="range"
            name="duration_min"
            min="5"
            max="60"
            step="5"
            value={@input.duration_min}
            class="flex-1"
          />
          <div class="flex items-center gap-1 w-20">
            <input
              type="number"
              name="duration_min"
              min="5"
              max="60"
              value={@input.duration_min}
              class="w-full rounded-md border border-base-300 px-2 py-1.5 text-sm text-right"
            />
            <span class="text-sm text-base-content/60 shrink-0">min</span>
          </div>
        </div>
        <.wizard_nav back={false} />
      </form>
    </div>
    """
  end

  # Step 2 — Burpee type
  defp wizard_step_type(assigns) do
    ~H"""
    <div class="space-y-4">
      <div>
        <p class="text-base font-medium">Burpee type</p>
      </div>
      <div class="grid grid-cols-2 gap-3">
        <button
          type="button"
          phx-click="wizard_pick_type"
          phx-value-type="six_count"
          class="rounded-xl border-2 border-base-300 p-6 text-center font-semibold hover:border-primary hover:bg-primary/5 transition active:scale-[0.97]"
        >
          6-Count
        </button>
        <button
          type="button"
          phx-click="wizard_pick_type"
          phx-value-type="navy_seal"
          class="rounded-xl border-2 border-base-300 p-6 text-center font-semibold hover:border-primary hover:bg-primary/5 transition active:scale-[0.97]"
        >
          Navy SEAL
        </button>
      </div>
      <.wizard_nav />
    </div>
    """
  end

  # Step 3 — Total burpees
  defp wizard_step_count(assigns) do
    ~H"""
    <div class="space-y-4">
      <div>
        <p class="text-base font-medium">Total burpees</p>
        <p class="text-sm text-base-content/60">{wizard_rate_hint(@input)}</p>
      </div>
      <form phx-submit="wizard_next" class="space-y-4">
        <input
          type="number"
          name="burpee_count"
          min="1"
          value={@input.burpee_count}
          class="w-full rounded-md border border-base-300 px-3 py-2 text-lg font-medium"
          autofocus
        />
        <.wizard_nav />
      </form>
    </div>
    """
  end

  # Step 4 — Sec per burpee
  defp wizard_step_pace(assigns) do
    ~H"""
    <div class="space-y-4">
      <div>
        <p class="text-base font-medium">Seconds per burpee</p>
        <p class="text-sm text-base-content/60">{wizard_pace_summary(@input)}</p>
      </div>
      <form phx-submit="wizard_next" class="space-y-4">
        <input type="hidden" name="confirm_pace" value="1" />
        <div class="flex items-center justify-center gap-4">
          <button
            type="button"
            phx-click="wizard_adjust_pace"
            phx-value-delta="-0.5"
            class="rounded-full border border-base-300 w-10 h-10 text-xl font-bold hover:bg-base-200 transition"
          >
            −
          </button>
          <span class="text-3xl font-semibold tabular-nums w-16 text-center">
            {:erlang.float_to_binary(@input.sec_per_burpee * 1.0, decimals: 1)}
          </span>
          <button
            type="button"
            phx-click="wizard_adjust_pace"
            phx-value-delta="0.5"
            class="rounded-full border border-base-300 w-10 h-10 text-xl font-bold hover:bg-base-200 transition"
          >
            +
          </button>
        </div>
        <.wizard_nav />
      </form>
    </div>
    """
  end

  # Step 5 — Pacing style
  defp wizard_step_pacing(assigns) do
    ~H"""
    <div class="space-y-4">
      <div>
        <p class="text-base font-medium">Pacing style</p>
      </div>
      <div class="grid grid-cols-2 gap-3">
        <button
          type="button"
          phx-click="wizard_pick_pacing"
          phx-value-style="even"
          class="rounded-xl border-2 border-base-300 p-5 text-center hover:border-primary hover:bg-primary/5 transition active:scale-[0.97]"
        >
          <p class="font-semibold">Even pacing</p>
          <p class="text-xs text-base-content/60 mt-1">Equal sets, consistent rest</p>
        </button>
        <button
          type="button"
          phx-click="wizard_pick_pacing"
          phx-value-style="unbroken"
          class="rounded-xl border-2 border-base-300 p-5 text-center hover:border-primary hover:bg-primary/5 transition active:scale-[0.97]"
        >
          <p class="font-semibold">Unbroken sets</p>
          <p class="text-xs text-base-content/60 mt-1">Large sets, micro-rest</p>
        </button>
      </div>
      <.wizard_nav />
    </div>
    """
  end

  # Step 6 — Extra rest
  defp wizard_step_extra(assigns) do
    ~H"""
    <div class="space-y-4">
      <div>
        <p class="text-base font-medium">Extra rest block?</p>
        <p class="text-sm text-base-content/60">
          Insert a longer pause at a minute mark. The planner shaves cadence or
          end-of-set rests to keep the total within your target time.
        </p>
      </div>
      <div class="flex items-center gap-3">
        <button
          type="button"
          phx-click="wizard_toggle_extra_rest"
          class={[
            "relative inline-flex h-6 w-11 items-center rounded-full transition",
            if(@input.extra_rest_enabled, do: "bg-primary", else: "bg-base-300")
          ]}
        >
          <span class={[
            "inline-block h-4 w-4 transform rounded-full bg-white transition",
            if(@input.extra_rest_enabled, do: "translate-x-6", else: "translate-x-1")
          ]} />
        </button>
        <span class="text-sm">{if @input.extra_rest_enabled, do: "On", else: "Off"}</span>
      </div>

      <%= if @input.extra_rest_enabled do %>
        <div class="grid grid-cols-2 gap-3 text-sm">
          <div class="space-y-1">
            <label class="text-base-content/60">At minute</label>
            <input
              type="number"
              min="1"
              max={@input.duration_min - 1}
              value={@input.extra_rest_at_min}
              phx-blur="wizard_update_extra"
              phx-value-field="extra_rest_at_min"
              name="extra_rest_at_min"
              class="w-full rounded-md border border-base-300 px-2 py-1.5"
            />
          </div>
          <div class="space-y-1">
            <label class="text-base-content/60">Rest (sec)</label>
            <input
              type="number"
              min="1"
              value={@input.extra_rest_sec}
              phx-blur="wizard_update_extra"
              phx-value-field="extra_rest_sec"
              name="extra_rest_sec"
              class="w-full rounded-md border border-base-300 px-2 py-1.5"
            />
          </div>
        </div>
      <% end %>

      <div class="flex gap-2 pt-2">
        <button
          type="button"
          phx-click="wizard_back"
          class="rounded-md border border-base-300 px-4 py-2 text-sm hover:bg-base-200 transition"
        >
          ← Back
        </button>
        <button
          type="button"
          phx-click="wizard_generate"
          class="flex-1 rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
        >
          Generate plan →
        </button>
      </div>
    </div>
    """
  end

  attr :back, :boolean, default: true
  attr :show_next, :boolean, default: true
  attr :label, :string, default: "Next →"

  defp wizard_nav(assigns) do
    ~H"""
    <div class="flex gap-2">
      <%= if @back do %>
        <button
          type="button"
          phx-click="wizard_back"
          class="rounded-md border border-base-300 px-4 py-2 text-sm hover:bg-base-200 transition"
        >
          ← Back
        </button>
      <% end %>

      <%= if @show_next do %>
        <button
          type="submit"
          class="flex-1 rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
        >
          {@label}
        </button>
      <% end %>
    </div>
    """
  end
end
