defmodule BurpeeTrainerWeb.WorkoutLibraryComponents do
  @moduledoc "Calm lifecycle cards for the durable workout library."

  use BurpeeTrainerWeb, :html

  alias BurpeeTrainer.Workouts.WorkoutPlan

  attr(:id, :string, required: true)
  attr(:plan, WorkoutPlan, required: true)
  attr(:owned?, :boolean, required: true)
  attr(:client_session_id, :string, required: true)

  def published_workout(assigns) do
    ~H"""
    <article
      id={@id}
      class="rounded-3xl border border-[var(--session-border)] bg-[var(--session-surface)]/70 p-6 shadow-sm"
    >
      <div class="flex items-start justify-between gap-5">
        <div class="min-w-0 space-y-2">
          <p class="text-xs font-semibold uppercase tracking-[0.18em] text-[var(--session-muted)]">
            {origin_label(@plan)}
          </p>
          <h2 class="truncate text-2xl font-semibold tracking-[-0.04em] text-[var(--session-ink)]">
            {@plan.name}
          </h2>
          <p class="text-sm tabular-nums text-[var(--session-muted)]">
            {@plan.target_reps} reps · {div(@plan.target_duration_sec, 60)} min
          </p>
        </div>
        <.qs_property_tag tone="info">Published</.qs_property_tag>
      </div>

      <div class="mt-6 grid grid-cols-2 gap-2 sm:grid-cols-3">
        <button
          id={"start-workout-#{@plan.id}"}
          type="button"
          phx-click="start"
          phx-value-id={@plan.id}
          phx-value-client-session-id={@client_session_id}
          phx-disable-with="Starting…"
          class="col-span-2 min-h-12 rounded-2xl bg-[var(--session-ink)] px-5 py-3 text-sm font-semibold text-[var(--session-bg)] transition hover:opacity-90 active:scale-[0.99] sm:col-span-1"
        >
          Start
        </button>
        <button
          id={"copy-workout-#{@plan.id}"}
          type="button"
          phx-click="copy"
          phx-value-id={@plan.id}
          class="min-h-12 rounded-2xl border border-[var(--session-border)] px-4 py-3 text-sm font-medium text-[var(--session-ink)] transition hover:bg-[var(--session-track)]/60"
        >
          Copy
        </button>
        <button
          :if={@owned?}
          id={"archive-workout-#{@plan.id}"}
          type="button"
          phx-click="archive"
          phx-value-id={@plan.id}
          class="min-h-12 rounded-2xl px-4 py-3 text-sm font-medium text-[var(--session-muted)] transition hover:bg-[var(--session-track)]/60 hover:text-[var(--session-ink)]"
        >
          Archive
        </button>
      </div>
    </article>
    """
  end

  attr(:id, :string, required: true)
  attr(:plan, WorkoutPlan, required: true)
  attr(:form, :any, required: true)

  def draft_workout(assigns) do
    ~H"""
    <article
      id={@id}
      class="rounded-3xl border border-[var(--session-border)] bg-[var(--session-surface)]/55 p-6"
    >
      <div class="flex items-start justify-between gap-5">
        <div class="min-w-0 space-y-2">
          <p class="text-xs font-semibold uppercase tracking-[0.18em] text-[var(--session-muted)]">
            Draft
          </p>
          <h2 class="truncate text-xl font-semibold tracking-[-0.03em] text-[var(--session-ink)]">
            {@plan.name}
          </h2>
          <p class="text-sm tabular-nums text-[var(--session-muted)]">
            {@plan.target_reps} reps · {div(@plan.target_duration_sec, 60)} min
          </p>
        </div>
      </div>

      <.form
        for={@form}
        id={"refine-workout-#{@plan.id}"}
        phx-submit="refine"
        phx-value-id={@plan.id}
        class="mt-5 space-y-3"
      >
        <.input
          field={@form[:request]}
          id={"refine-workout-request-#{@plan.id}"}
          type="textarea"
          label="Describe what should change"
          maxlength="500"
          rows="2"
          placeholder="Make the rests shorter and keep the same duration"
        />
        <button
          type="submit"
          phx-disable-with="Refining…"
          class="min-h-11 rounded-xl border border-[var(--session-border)] px-4 py-2 text-sm font-medium text-[var(--session-ink)] transition hover:bg-[var(--session-track)]/60"
        >
          Refine
        </button>
      </.form>

      <div class="mt-4 flex flex-wrap gap-2 border-t border-[var(--session-border)] pt-4">
        <button
          id={"publish-workout-#{@plan.id}"}
          type="button"
          phx-click="publish"
          phx-value-id={@plan.id}
          class="min-h-11 rounded-xl bg-[var(--session-ink)] px-4 py-2 text-sm font-semibold text-[var(--session-bg)] transition hover:opacity-90"
        >
          Publish
        </button>
        <button
          id={"delete-draft-#{@plan.id}"}
          type="button"
          phx-click="delete_draft"
          phx-value-id={@plan.id}
          class="min-h-11 rounded-xl px-4 py-2 text-sm font-medium text-[var(--session-muted)] transition hover:bg-red-50 hover:text-red-700 dark:hover:bg-red-950/30"
        >
          Delete
        </button>
      </div>
    </article>
    """
  end

  defp origin_label(%WorkoutPlan{origin: :built_in}), do: "Built in"
  defp origin_label(%WorkoutPlan{origin: :coach}), do: "Coach"
  defp origin_label(%WorkoutPlan{}), do: "Your workout"
end
