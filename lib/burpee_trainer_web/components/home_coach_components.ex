defmodule BurpeeTrainerWeb.HomeCoachComponents do
  @moduledoc "The coach summary, and the coach on Home once today's training is done."

  use BurpeeTrainerWeb, :html

  attr(:summary, :any, required: true)
  attr(:loading?, :boolean, required: true)
  attr(:field, :atom, default: :text, values: [:text, :review])

  @doc "The coach's note (or its look back), or the app's loader while a refresh is on its way."
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
    <span :if={not @loading? and @summary} class="coach-summary-text">
      {Map.fetch!(@summary, @field)}
    </span>
    """
  end

  # What you might say next: the last reply's suggestions, else the note's, else two
  # plain asks that always make sense.
  defp quick_replies(state) do
    exchange = state |> Map.get(:coach_thread, []) |> List.last()
    summary = Map.get(state, :progress_summary)

    predicted =
      cond do
        exchange && exchange.suggestions != [] -> exchange.suggestions
        is_nil(exchange) && summary && summary.suggestions != [] -> summary.suggestions
        true -> []
      end

    case predicted do
      [] -> [{"harder", "Make the next one harder"}, {"easier", "Make the next one easier"}]
      texts -> Enum.with_index(texts, &{"predicted-#{&2}", &1})
    end
  end

  attr(:state, :map, required: true)

  # The coach is a card. The front is this week: what is done and left of the training
  # window, the coach's word on the rest of it, and the conversation. The back, turned
  # over with the book, is what the coach knows about you.
  # See docs/specs/2026-10-14-coach-card-design.md.
  def panel(assigns) do
    ~H"""
    <section
      id="home-coach-panel"
      class="home-coach-panel coach-card"
      data-flipped={to_string(@state.coach_flipped?)}
      aria-label="Coach"
    >
      <div class="coach-card-inner">
        <div
          id="home-coach-front"
          class="coach-card-face coach-card-front"
          inert={@state.coach_flipped?}
          aria-hidden={to_string(@state.coach_flipped?)}
        >
          <div class="coach-card-header">
            <h2>This week</h2>
            <button
              id="home-coach-flip"
              type="button"
              class="home-text-action home-icon-action"
              phx-click="coach_flip"
              aria-label="What the coach knows about you"
              title="What the coach knows about you"
            >
              <.icon name="hero-book-open" class="size-5" />
            </button>
          </div>
          <ol :if={@state.coach_week != []} id="home-coach-week" class="coach-week">
            <li
              :for={{item, index} <- Enum.with_index(@state.coach_week)}
              id={"home-coach-week-#{index}"}
              class={["coach-week-item", "coach-week-#{item.status}"]}
              data-status={item.status}
            >
              <.icon
                name={
                  if(item.status == :done, do: "hero-check-circle-solid", else: "hero-minus-circle")
                }
                class="coach-week-mark size-5"
              />
              <span class="coach-week-type">
                {BurpeeTrainerWeb.Fmt.burpee_type(item.burpee_type)}
              </span>
              <span class="coach-week-when">
                {week_when(item, @state.current_scope.user.timezone)}
              </span>
            </li>
          </ol>
          <%!-- The coach's word on the rest of the week. --%>
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
          <%!-- This week's conversation, kept across reloads. --%>
          <ol
            :if={@state.coach_thread != [] or @state.coach_pending_message}
            id="home-coach-thread"
            class="coach-thread"
            aria-label="Conversation with the coach"
          >
            <li
              :for={exchange <- @state.coach_thread}
              id={"home-coach-exchange-#{exchange.id}"}
              class="coach-exchange"
            >
              <p class="coach-exchange-you">{exchange.message}</p>
              <p>{exchange.reply}</p>
            </li>
            <li
              :if={@state.coach_busy? and @state.coach_pending_message}
              id="home-coach-pending"
              class="coach-exchange"
            >
              <p class="coach-exchange-you">{@state.coach_pending_message}</p>
            </li>
          </ol>
          <div class="coach-quick-replies" role="group" aria-label="Quick replies">
            <button
              :for={{id, text} <- quick_replies(@state)}
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
              aria-label="Send"
              title="Send"
            >
              <.icon name="hero-arrow-up" class="size-5" />
            </button>
          </.form>
          <p
            :if={@state.coach_busy?}
            id="home-coach-loading"
            role="status"
            class="coach-guidance-status"
          >
            Sending to the coach
          </p>
          <p id="home-coach-reply" role="status" class="coach-guidance-status">
            {@state.coach_reply}
          </p>
          <p id="home-coach-status" role="status" class="coach-guidance-status">
            {@state.coach_status}
          </p>
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
                class="home-text-action home-icon-action"
                aria-label="Dismiss goal"
                title="Dismiss"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
              <button
                :if={goal.status == :proposed}
                id={"home-coach-goal-#{goal.id}-confirm"}
                type="button"
                phx-click="coach_goal_confirm"
                phx-value-id={goal.id}
                class="home-primary-action home-icon-action"
                aria-label="Confirm goal"
                title="Confirm"
              >
                <.icon name="hero-check" class="size-5" />
              </button>
            </div>
          </div>
        </div>
        <div
          id="home-coach-notebook"
          class="coach-card-face coach-card-back"
          inert={not @state.coach_flipped?}
          aria-hidden={to_string(not @state.coach_flipped?)}
        >
          <div class="coach-card-header">
            <h2>What the coach knows about you</h2>
            <button
              id="home-coach-unflip"
              type="button"
              class="home-text-action home-icon-action"
              phx-click="coach_flip"
              aria-label="Back to this week"
              title="Back to this week"
            >
              <.icon name="hero-arrow-uturn-left" class="size-5" />
            </button>
          </div>
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
              rows="6"
              maxlength="4000"
              placeholder="Nothing yet. The coach notes what matters as you talk."
              class="home-authoring-input coach-notebook-input"
            />
            <div class="home-review-actions">
              <button
                id="home-coach-notebook-clear"
                type="button"
                phx-click="coach_notebook_clear"
                class="home-text-action home-icon-action"
                aria-label="Clear notes"
                title="Clear"
              >
                <.icon name="hero-trash" class="size-5" />
              </button>
              <button
                id="home-coach-notebook-save"
                type="submit"
                class="home-primary-action home-icon-action"
                aria-label="Save notes"
                title="Save"
              >
                <.icon name="hero-check" class="size-5" />
              </button>
            </div>
          </.form>
        </div>
      </div>
    </section>
    """
  end

  # Done: the day it was done and its minutes. Left: its minutes.
  defp week_when(%{status: :done, completed_at: at, duration_sec: sec}, timezone) do
    day =
      case DateTime.shift_zone(at, timezone) do
        {:ok, local} -> Calendar.strftime(local, "%a")
        {:error, _} -> Calendar.strftime(at, "%a")
      end

    "#{day}, #{div(sec, 60)} min"
  end

  defp week_when(%{status: :left, duration_sec: sec}, _timezone), do: "#{div(sec, 60)} min"
end
