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
    >
      <%!-- The coach speaks first: what to do next, in a sentence or two. --%>
      <p id="home-coach-note" class="coach-note">
        <.summary_body
          :if={@state.progress_summary || @state.progress_summary_loading?}
          summary={@state.progress_summary}
          loading?={@state.progress_summary_loading?}
        />
        <span :if={is_nil(@state.progress_summary) and not @state.progress_summary_loading?}>
          Tell me what you're training for, or how the last session felt.
        </span>
      </p>
      <%!-- The last exchange, kept across reloads: what you said, then what the coach said. --%>
      <div :if={@state.coach_exchange} id="home-coach-exchange" class="coach-exchange">
        <p class="coach-exchange-you">{@state.coach_exchange.message}</p>
        <p>{@state.coach_exchange.reply}</p>
      </div>
      <div class="coach-quick-replies" role="group" aria-label="Quick replies">
        <button
          :for={
            {id, text} <- [
              {"harder", "Make the next one harder"},
              {"easier", "Make the next one easier"}
            ]
          }
          id={"home-coach-quick-#{id}"}
          type="button"
          class="home-selection-pill"
          phx-click="coach_quick_reply"
          phx-value-text={text}
          disabled={@state.coach_busy?}
        >
          {text}
        </button>
      </div>
      <.form
        for={@state.coach_message_form}
        id="home-coach-message-form"
        phx-submit="coach_message"
        phx-change="coach_message_change"
        class="coach-message-form home-authoring-form coach-quiet-label"
      >
        <.input
          field={@state.coach_message_form[:text]}
          id="home-coach-message-text"
          type="textarea"
          label="Message the coach"
          rows="1"
          maxlength="1000"
          placeholder="Message the coach"
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
      <details id="home-coach-notebook" class="history-coach-memory" open={@state.coach_details_open?}>
        <summary id="home-coach-notebook-toggle" phx-click="coach_details_toggle">
          What the coach knows about you
          <.icon name="hero-chevron-down" class="history-coach-memory-chevron size-4" />
        </summary>
        <.form
          for={@state.coach_notebook_form}
          id="home-coach-notebook-form"
          phx-submit="coach_notebook_save"
          phx-change="coach_notebook_change"
          class="home-authoring-form coach-quiet-label"
        >
          <.input
            field={@state.coach_notebook_form[:text]}
            id="home-coach-notebook-text"
            type="textarea"
            label="Coach's notes"
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
