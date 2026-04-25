defmodule BurpeeTrainerWeb.PlansLive.Edit do
  @moduledoc """
  Plan editor used for both `:new` and `:edit`. Dynamic blocks and sets
  are driven by `cast_assoc`'s `sort_param`/`drop_param` mechanism — no
  server-side state is needed to add or remove rows, the form itself
  carries the intent.

  A live summary sidebar is recomputed on every `"validate"` event from
  `Planner.summary/1` applied to `Changeset.apply_changes/1`.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}
  alias BurpeeTrainer.Planner
  alias BurpeeTrainerWeb.Fmt

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:live_action, socket.assigns.live_action)
     |> load_plan(params)
     |> build_form()}
  end

  defp load_plan(socket, %{"id" => id}) do
    plan =
      socket.assigns.current_user
      |> Workouts.get_plan!(String.to_integer(id))
      |> preload_duration_min()

    assign(socket, plan: plan, page_title: "Edit plan")
  end

  defp load_plan(socket, _params) do
    plan =
      %WorkoutPlan{
        name: "",
        burpee_type: :six_count,
        warmup_enabled: false,
        rest_sec_warmup_between: 120,
        rest_sec_warmup_before_main: 180,
        blocks: [
          %Block{
            position: 1,
            repeat_count: 1,
            sets: [
              %Set{
                position: 1,
                burpee_count: 10,
                sec_per_rep: 6.0,
                sec_per_burpee: 3.0,
                end_of_set_rest: 30
              },
              %Set{
                position: 2,
                burpee_count: 10,
                sec_per_rep: 6.0,
                sec_per_burpee: 3.0,
                end_of_set_rest: 0
              }
            ]
          }
        ]
      }
      |> preload_duration_min()

    assign(socket, plan: plan, page_title: "New plan")
  end

  # Fill the virtual `duration_min` on every set from its existing
  # work-time + rest-time so the form edit input shows the right value.
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

  defp build_form(socket) do
    changeset = Workouts.change_plan(socket.assigns.plan)

    socket
    |> assign(:form, to_form(changeset))
    |> assign_summary(changeset)
  end

  @impl true
  def handle_event("validate", %{"workout_plan" => params}, socket) do
    changeset =
      socket.assigns.plan
      |> Workouts.change_plan(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign_summary(changeset)}
  end

  def handle_event("save", %{"workout_plan" => params}, socket) do
    save_plan(socket, socket.assigns.live_action, params)
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
         |> assign_summary(changeset)}
    end
  end

  defp save_plan(socket, :edit, params) do
    case Workouts.update_plan(socket.assigns.plan, params) do
      {:ok, plan} ->
        {:noreply,
         socket
         |> assign(:plan, Workouts.preload_plan(plan))
         |> put_flash(:info, "Plan saved.")
         |> build_form()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> assign_summary(changeset)}
    end
  end

  # Build a summary from the current changeset if the plan is complete
  # enough for the Planner to compute one. Otherwise nil — the sidebar
  # renders a placeholder.
  defp assign_summary(socket, changeset) do
    summary =
      try do
        plan = Ecto.Changeset.apply_changes(changeset)

        if can_summarize?(plan) do
          Planner.summary(plan)
        end
      rescue
        _ -> nil
      end

    assign(socket, :summary, summary)
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_level={@current_level}>
      <.form
        for={@form}
        id="plan-form"
        phx-change="validate"
        phx-submit="save"
        class="grid gap-8 lg:grid-cols-[1fr_20rem]"
      >
        <div class="space-y-8">
          <div class="flex items-center justify-between">
            <h1 class="text-2xl font-semibold tracking-tight">{@page_title}</h1>
            <div class="flex gap-2">
              <.link
                navigate={~p"/plans"}
                class="rounded-md border border-base-300 px-4 py-2 text-sm hover:bg-base-200 transition"
              >
                Cancel
              </.link>
              <button
                type="submit"
                class="rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
              >
                Save plan
              </button>
            </div>
          </div>

          <section class="rounded-lg border border-base-300 bg-base-100 p-6 space-y-4">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              Basics
            </h2>
            <div class="grid gap-4 sm:grid-cols-2">
              <.input field={@form[:name]} type="text" label="Name" />
              <.input
                field={@form[:burpee_type]}
                type="select"
                label="Burpee type"
                options={[{"6-count", "six_count"}, {"Navy SEAL", "navy_seal"}]}
              />
            </div>
          </section>

          <.warmup_section form={@form} />
          <.shave_off_section form={@form} summary={@summary} />
          <.blocks_section form={@form} />
        </div>

        <aside class="lg:sticky lg:top-6 self-start">
          <.summary_sidebar summary={@summary} />
        </aside>
      </.form>
    </Layouts.app>
    """
  end

  # -- sections --

  attr :form, :any, required: true

  defp warmup_section(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100 p-6 space-y-4">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Warmup</h2>
        <label class="inline-flex items-center gap-2 text-sm">
          <input
            type="hidden"
            name={@form[:warmup_enabled].name}
            value="false"
          />
          <input
            type="checkbox"
            name={@form[:warmup_enabled].name}
            value="true"
            checked={@form[:warmup_enabled].value in [true, "true"]}
            class="checkbox checkbox-sm"
          /> Enable warmup
        </label>
      </div>

      <div class={[
        "grid gap-4 sm:grid-cols-2",
        @form[:warmup_enabled].value not in [true, "true"] && "opacity-50"
      ]}>
        <.input field={@form[:warmup_reps]} type="number" label="Reps per round" min="1" />
        <.input field={@form[:warmup_rounds]} type="number" label="Rounds" min="1" />
        <.input
          field={@form[:rest_sec_warmup_between]}
          type="number"
          label="Rest between rounds (sec)"
          min="0"
        />
        <.input
          field={@form[:rest_sec_warmup_before_main]}
          type="number"
          label="Rest before main (sec)"
          min="0"
        />
      </div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :summary, :any, default: nil

  defp shave_off_section(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100 p-6 space-y-4">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
        Shave-off rest
      </h2>
      <p class="text-xs text-base-content/60">
        Extra rest injected after the first N blocks, accumulating the seconds saved per repetition.
      </p>
      <div class="grid gap-4 sm:grid-cols-2">
        <.input
          field={@form[:shave_off_sec]}
          type="number"
          label="Seconds saved per repetition"
          min="0"
        />
        <.input
          field={@form[:shave_off_block_count]}
          type="number"
          label="Apply after block #"
          min="0"
        />
      </div>
    </section>
    """
  end

  attr :form, :any, required: true

  defp blocks_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Blocks</h2>
          <p class="text-xs text-base-content/60">
            A block repeats its sets <em>repeat count</em> times.
          </p>
        </div>
        <label class="cursor-pointer rounded-md bg-primary/10 px-3 py-1.5 text-sm text-primary hover:bg-primary/20 transition">
          + Add block <input type="checkbox" name="workout_plan[blocks_sort][]" class="hidden" />
        </label>
      </div>

      <.inputs_for :let={block_f} field={@form[:blocks]}>
        <div class="rounded-lg border border-base-300 bg-base-100 p-5 space-y-4">
          <input type="hidden" name="workout_plan[blocks_sort][]" value={block_f.index} />

          <div class="flex items-center justify-between">
            <h3 class="text-base font-semibold">Block {block_f.index + 1}</h3>
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

          <input
            type="hidden"
            name={"workout_plan[blocks][#{block_f.index}][position]"}
            value={block_f.index + 1}
          />

          <div>
            <.input field={block_f[:repeat_count]} type="number" label="Repeat count" min="1" />
          </div>

          <div class="space-y-3">
            <div class="flex items-center justify-between">
              <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                Sets
              </h4>
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

                <div class="grid gap-3 sm:grid-cols-5 items-end">
                  <.input field={set_f[:burpee_count]} type="number" label="Burpees" min="0" />
                  <.input
                    field={set_f[:sec_per_rep]}
                    type="number"
                    label="Pacing (sec/rep)"
                    step="0.1"
                    min="0"
                  />
                  <.input
                    field={set_f[:sec_per_burpee]}
                    type="number"
                    label="Burpee (sec)"
                    step="0.1"
                    min="0"
                  />
                  <.input
                    field={set_f[:duration_min]}
                    type="number"
                    label="Duration (min)"
                    min="1"
                  />
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
              name={"workout_plan[blocks][#{block_f.index}][sets_drop][]"}
            />
          </div>
        </div>
      </.inputs_for>

      <input type="hidden" name="workout_plan[blocks_drop][]" />
    </section>
    """
  end

  # -- sidebar --

  attr :summary, :any, default: nil

  defp summary_sidebar(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-100 p-5 space-y-4">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Summary</h2>

      <%= if @summary do %>
        <dl class="grid grid-cols-2 gap-3">
          <div>
            <dt class="text-xs text-base-content/60">Burpees</dt>
            <dd class="text-xl font-semibold">{@summary.burpee_count_total}</dd>
          </div>
          <div>
            <dt class="text-xs text-base-content/60">Duration</dt>
            <dd class="text-xl font-semibold">{Fmt.duration_sec(@summary.duration_sec_total)}</dd>
          </div>
        </dl>

        <div class="border-t border-base-200 pt-3 space-y-2">
          <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Per-block
          </h3>
          <ul class="space-y-2">
            <%= for block <- @summary.blocks do %>
              <li class="text-sm">
                <div class="flex items-center justify-between">
                  <span class="font-medium">Block {block.position} (×{block.repeat_count})</span>
                  <span class="text-base-content/60">{block.burpee_count_total} burpees</span>
                </div>
                <div class="text-xs text-base-content/50">
                  ~{Fmt.duration_sec(block.duration_sec_work)} work
                  + {Fmt.duration_sec(block.duration_sec_rest)} rest
                </div>
              </li>
            <% end %>
          </ul>
        </div>
      <% else %>
        <p class="text-sm text-base-content/60">
          Fill in burpee counts and seconds-per-burpee to see totals.
        </p>
      <% end %>
    </div>
    """
  end
end
