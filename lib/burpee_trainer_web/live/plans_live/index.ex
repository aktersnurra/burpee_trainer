defmodule BurpeeTrainerWeb.PlansLive.Index do
  @moduledoc """
  Plan list. Each card links to the three-layer editor for editing or to the
  session runner for execution.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Planner, Workouts}
  alias BurpeeTrainerWeb.Fmt

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_plans(socket)}
  end

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

  defp assign_plans(socket) do
    plans = Workouts.list_plans(socket.assigns.current_user)
    cards = Enum.map(plans, fn plan -> {plan, Planner.summary(plan)} end)
    assign(socket, :cards, cards)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_level={@current_level} current_page={:plans}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Plans</h1>
            <p class="text-sm text-base-content/60">Workouts you've built, ready to run.</p>
          </div>
          <.link
            navigate={~p"/plans/new"}
            class="rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
          >
            New plan
          </.link>
        </div>

        <%= if @cards == [] do %>
          <div class="rounded-lg border border-dashed border-base-300 p-12 text-center space-y-2">
            <p class="text-base-content/70">No plans yet.</p>
            <p class="text-sm text-base-content/50">Create your first plan to get started.</p>
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
end
