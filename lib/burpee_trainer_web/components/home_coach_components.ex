defmodule BurpeeTrainerWeb.HomeCoachComponents do
  @moduledoc "The coach summary and the Coach screen, reached only from History."

  use BurpeeTrainerWeb, :html

  attr(:summary, :any, required: true)
  attr(:loading?, :boolean, required: true)

  @doc "The coach summary text, or the app's loader while a refresh is on its way."
  def summary_body(assigns) do
    ~H"""
    <span :if={@loading?} role="status" class="coach-summary-loading">
      <img
        class="coach-summary-loader"
        src="/images/burpee-loader-ink.gif"
        alt=""
        width="40"
        height="40"
      />
      <span>Updating your summary</span>
    </span>
    <span :if={not @loading? and @summary} class="coach-summary-text">{@summary.text}</span>
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
    >
      <div id="home-coach-goals" phx-update="stream">
        <div
          :for={{dom_id, goal} <- @state.streams.coach_goals}
          id={dom_id}
          data-status={goal.status}
          class="history-coach-entry"
        >
          <p>{BurpeeTrainerWeb.Fmt.goal(goal)}</p>
          <button
            :if={goal.status == :proposed}
            id={"home-coach-goal-#{goal.id}-dismiss"}
            type="button"
            phx-click="coach_goal_dismiss"
            phx-value-id={goal.id}
            class="home-text-action"
          >
            Dismiss
          </button>
          <button
            :if={goal.status == :proposed}
            id={"home-coach-goal-#{goal.id}-confirm"}
            type="button"
            phx-click="coach_goal_confirm"
            phx-value-id={goal.id}
            class="home-primary-action"
          >
            Confirm
          </button>
        </div>
      </div>
      <.form
        for={@state.coach_message_form}
        id="home-coach-message-form"
        phx-submit="coach_message"
        phx-change="coach_message_change"
        class="coach-message-form home-authoring-form"
      >
        <.input
          field={@state.coach_message_form[:text]}
          id="home-coach-message-text"
          type="textarea"
          label="Tell the coach"
          rows="1"
          maxlength="1000"
          placeholder="A goal, a niggle, what you'd like next"
          class="home-authoring-input"
          disabled={@state.coach_busy?}
        />
        <%!-- Send sits inside the field and shows once there is something to send. --%>
        <button
          id="home-coach-message-send"
          type="submit"
          class="home-primary-action coach-send"
          disabled={@state.coach_busy?}
        >
          Send
        </button>
      </.form>
      <p :if={@state.coach_busy?} id="home-coach-loading" role="status" class="coach-guidance-status">
        Sending to the coach
      </p>
      <p id="home-coach-reply" role="status" class="coach-guidance-status">{@state.coach_reply}</p>
      <p id="home-coach-status" role="status" class="coach-guidance-status">{@state.coach_status}</p>
      <details id="home-coach-notebook" class="history-coach-memory" open={@state.coach_details_open?}>
        <summary id="home-coach-notebook-toggle" phx-click="coach_details_toggle">
          What the coach knows
          <.icon name="hero-chevron-down" class="history-coach-memory-chevron size-4" />
        </summary>
        <.form
          for={@state.coach_notebook_form}
          id="home-coach-notebook-form"
          phx-submit="coach_notebook_save"
          phx-change="coach_notebook_change"
          class="home-authoring-form"
        >
          <.input
            field={@state.coach_notebook_form[:text]}
            id="home-coach-notebook-text"
            type="textarea"
            label="Coach notebook"
            rows="1"
            maxlength="4000"
            class="home-authoring-input"
          />
          <div class="home-review-actions">
            <button
              id="home-coach-notebook-clear"
              type="button"
              phx-click="coach_notebook_clear"
              class="home-text-action"
            >
              Clear
            </button>
            <button id="home-coach-notebook-save" type="submit" class="home-primary-action">
              Save
            </button>
          </div>
        </.form>
      </details>
    </section>
    """
  end
end
