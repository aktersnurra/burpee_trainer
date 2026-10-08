defmodule BurpeeTrainerWeb.HomeCoachComponents do
  @moduledoc "Small recommendation-first presentation primitives for Home."

  use BurpeeTrainerWeb, :html

  attr(:id, :string, required: true)
  attr(:return_focus?, :boolean, default: false)

  def entry(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={if(@id == "history-coach-open", do: ~p"/coach?from=history", else: ~p"/coach?from=home")}
      class="home-coach-entry"
      phx-mounted={@return_focus? && JS.focus(to: "#" <> @id)}
    >
      <.icon name="hero-chat-bubble-left-right" class="size-5" />
      <span>Coach</span>
    </.link>
    """
  end

  attr(:state, :map, required: true)

  def panel(assigns) do
    ~H"""
    <section
      id="home-coach-panel"
      class="home-coach-panel"
      aria-label="Coach"
      phx-window-keydown="close_coach"
      phx-key="Escape"
      phx-mounted={JS.focus(to: "#home-coach-heading")}
    >
      <button
        id="home-coach-back"
        type="button"
        class="home-state-action min-h-11 min-w-11"
        aria-label={
          if(@state.coach_return_to == "/history",
            do: "Back to History",
            else: "Back to workout"
          )
        }
        phx-click="close_coach"
      >
        <.icon name="hero-arrow-left" class="size-5" />
      </button>
      <h1 id="home-coach-heading" tabindex="-1" class="home-state-heading">Coach</h1>
      <section id="home-coach-summary" aria-label="Your summary">
        <p class="home-coach-baseline">
          {if(@state.current_level == :graduated,
            do: "Graduated",
            else:
              "Level " <>
                (@state.current_level
                 |> Atom.to_string()
                 |> String.replace_prefix("level_", "")
                 |> String.upcase())
          )}<span :if={@state.slot}> · {div(@state.slot.weekly_target_sec, 60)} min/week</span>
        </p>
        <p :if={@state.coach_summary != ""} class="home-coach-summary-text">{@state.coach_summary}</p>
        <div id="home-coach-goals" phx-update="stream">
          <div
            :for={{dom_id, goal} <- @state.streams.coach_goals}
            id={dom_id}
            data-status={goal.status}
            class="history-coach-entry"
          >
            <p>
              {if(goal.burpee_type == :six_count, do: "Six-count", else: "Navy seal")} · {goal.burpee_count_target} reps in {div(
                goal.duration_sec_target,
                60
              )} minutes by {goal.date_target} · {goal.status}
            </p>
            <button
              :if={goal.status == :proposed}
              id={"home-coach-goal-#{goal.id}-confirm"}
              type="button"
              phx-click="coach_goal_confirm"
              phx-value-id={goal.id}
              class="home-state-action"
            >
              Confirm
            </button>
            <button
              :if={goal.status == :proposed}
              id={"home-coach-goal-#{goal.id}-dismiss"}
              type="button"
              phx-click="coach_goal_dismiss"
              phx-value-id={goal.id}
              class="home-state-action"
            >
              Dismiss
            </button>
          </div>
        </div>
      </section>
      <details
        id="history-coach-memory"
        class="history-coach-memory"
        open={@state.coach_details_open?}
      >
        <summary id="history-coach-memory-toggle" phx-click="coach_details_toggle">Details</summary>
        <div id="history-coach-entries">
          <.form
            for={@state.coach_notebook_form}
            id="home-coach-notebook-form"
            phx-submit="coach_notebook_save"
            phx-change="coach_notebook_change"
          >
            <.input
              field={@state.coach_notebook_form[:text]}
              id="home-coach-notebook-text"
              type="textarea"
              label="Coach notebook"
              rows="4"
              maxlength="4000"
              class="coach-guidance-input"
            />
            <button id="home-coach-notebook-save" type="submit" class="home-state-action">
              Save
            </button>
            <button
              id="home-coach-notebook-clear"
              type="button"
              phx-click="coach_notebook_clear"
              class="home-state-action"
            >
              Clear
            </button>
          </.form>
        </div>
      </details>
      <.form
        for={@state.coach_message_form}
        id="home-coach-message-form"
        phx-submit="coach_message"
        phx-change="coach_message_change"
      >
        <div class="coach-guidance-row">
          <.input
            field={@state.coach_message_form[:text]}
            id="home-coach-message-text"
            type="textarea"
            label="New info"
            rows="2"
            maxlength="1000"
            placeholder="Add a goal or other info"
            class="coach-guidance-input"
            disabled={@state.coach_busy?}
          />
          <button
            id="home-coach-message-send"
            type="submit"
            aria-label="Send to coach"
            class="coach-guidance-send"
            disabled={@state.coach_busy?}
            phx-disable-with="Sending…"
          >
            <.icon name="hero-arrow-up" class="size-5" />
          </button>
        </div>
      </.form>
      <p :if={@state.coach_busy?} id="home-coach-loading" role="status" class="coach-guidance-status">
        Sending…
      </p>
      <p id="home-coach-reply" role="status" class="coach-guidance-status">{@state.coach_reply}</p>
      <p id="home-coach-status" role="status" class="coach-guidance-status">{@state.coach_status}</p>
    </section>
    """
  end
end
