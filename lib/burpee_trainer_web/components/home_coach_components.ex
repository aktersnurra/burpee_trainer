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

  # The coach is a section of Home, not a card: its word on the rest of the week, this
  # week's window in Progress's rows, then the conversation as a chat, with what it noted
  # or forgot about you as quiet lines between exchanges.
  # See docs/specs/2026-10-14-coach-card-design.md.
  def panel(assigns) do
    ~H"""
    <section id="home-coach-panel" class="home-coach-panel" aria-label="Coach">
      <%!-- The coach's word on the rest of the week leads. --%>
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
      <%!-- This week's window as Progress's rows: what is done, then what is left, muted. --%>
      <ol
        :if={@state.coach_week != []}
        id="home-coach-week"
        class="coach-week"
        aria-label="This week"
      >
        <li
          :for={{item, index} <- Enum.with_index(@state.coach_week)}
          id={"home-coach-week-#{index}"}
          class={["coach-week-item", "coach-week-#{item.status}"]}
          data-status={item.status}
        >
          <span class={["coach-week-type", "progress-key-#{series_class(item.burpee_type)}"]}>
            {BurpeeTrainerWeb.Fmt.burpee_type(item.burpee_type)}
          </span>
          <span class="coach-week-when">
            {week_when(item, @state.current_scope.user.timezone)}
          </span>
        </li>
      </ol>
      <%!-- This week's conversation as a chat: you on the right, the coach on the left, what
           it noted between. Kept across reloads. --%>
      <ol
        :if={thread_items(@state) != [] or @state.coach_pending_message}
        id="home-coach-thread"
        class="coach-thread"
        aria-label="Conversation with the coach"
      >
        <%= for item <- thread_items(@state) do %>
          <li
            :if={match?({:exchange, _}, item)}
            id={"home-coach-exchange-#{elem(item, 1).id}"}
            class="coach-exchange"
          >
            <p class="coach-exchange-you">{elem(item, 1).message}</p>
            <p class="coach-exchange-coach">{elem(item, 1).reply}</p>
          </li>
          <li :if={match?({:memory, _}, item)} class="coach-memory" data-kind={elem(item, 1).kind}>
            <.icon
              name={
                if(elem(item, 1).kind == :noted, do: "hero-bookmark", else: "hero-bookmark-slash")
              }
              class="size-4"
            />
            <span>
              {if(elem(item, 1).kind == :noted, do: "Noted: ", else: "Forgot: ")}{elem(item, 1).text}
            </span>
          </li>
        <% end %>
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
          <.icon name="hero-arrow-turn-down-left" class="size-5" />
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
    </section>
    """
  end

  defp series_class(type), do: type |> Atom.to_string() |> String.replace("_", "-")

  # Exchanges and memory changes, in the order they happened.
  defp thread_items(state) do
    exchanges = Enum.map(Map.get(state, :coach_thread, []), &{:exchange, &1})
    changes = Enum.map(Map.get(state, :coach_memory_changes, []), &{:memory, &1})

    Enum.sort_by(exchanges ++ changes, &item_at/1, DateTime)
  end

  defp item_at({:exchange, exchange}), do: exchange.inserted_at
  defp item_at({:memory, change}), do: change.at

  # Done: the day it was done and its minutes. Left: its minutes.
  defp week_when(%{status: :done, completed_at: at, duration_sec: sec}, timezone) do
    day =
      case DateTime.shift_zone(at, timezone) do
        {:ok, local} -> Calendar.strftime(local, "%a")
        {:error, _} -> Calendar.strftime(at, "%a")
      end

    "#{day} · #{div(sec, 60)} min"
  end

  defp week_when(%{status: :left, duration_sec: sec}, _timezone), do: "#{div(sec, 60)} min"
end
