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
      <.burpee_loader class="coach-summary-loader" size={40} />
      <span>Updating your summary</span>
    </span>
    <span :if={not @loading? and @summary} class="coach-summary-text">
      {Map.fetch!(@summary, @field)}
    </span>
    """
  end

  attr(:state, :map, required: true)

  # The coach is a section of Home, not a card: its word on the rest of the week, this
  # week's window in Progress's rows, then the conversation as a chat, with what it noted
  # or forgot about you as quiet lines between exchanges.
  # See docs/specs/2026-10-14-coach-card-design.md.
  def panel(assigns) do
    ~H"""
    <section id="home-coach-panel" class="home-coach-panel" aria-label="Coach">
      <%!-- The coach's word on the rest of the week leads; what it remembers is an icon
           beside it, opened on asking. --%>
      <div class="coach-head">
        <p id="home-coach-note" class="coach-note">
          <.summary_body
            :if={@state.progress_summary || @state.progress_summary_loading?}
            summary={@state.progress_summary}
            loading?={@state.progress_summary_loading?}
          />
          <span :if={
            coach?(@state) and is_nil(@state.progress_summary) and
              not @state.progress_summary_loading?
          }>
            Tell me what you're training for, or how the last session felt.
          </span>
        </p>
        <.memory_button :if={memory_count(@state) > 0} state={@state} />
      </div>
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
            <.icon :if={item.status == :done} name="hero-check" class="size-4 coach-week-done-mark" />
            <span :if={item.status == :done} class="sr-only">done</span>
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
                if(elem(item, 1).kind == :forgot, do: "hero-bookmark-slash", else: "hero-bookmark")
              }
              class="size-4"
            />
            <span>{memory_verb(elem(item, 1).kind)}{elem(item, 1).text}</span>
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
      <p :if={@state.coach_busy?} id="home-coach-loading" role="status" class="coach-pending-status">
        <.burpee_loader class="coach-summary-loader" size={32} />
        <span>Sending to the coach</span>
      </p>
      <%!-- Talking to the app's coach needs it; without it the coach is Claude, and this
           section shows only what Claude left. --%>
      <%= if coach?(@state) do %>
        <%!-- The box rides above the keyboard, as in the design chat (see the ChatDock hook).
             Collapsed, the panel's visibility hides it with the rest. --%>
        <div
          id="home-coach-dock"
          class="chat-dock"
          phx-hook="ChatDock"
          data-version={coach_version(@state)}
          data-scroll-to="#home-coach-thread > :last-child"
          data-scroll-on-mount="false"
        >
          <div class="chat-dock-inner">
            <.form
              for={@state.coach_message_form}
              id="home-coach-message-form"
              phx-submit="coach_message"
              phx-change="coach_message_change"
              class="coach-message-form home-authoring-form composer"
            >
              <.input
                field={@state.coach_message_form[:text]}
                id="home-coach-message-text"
                type="textarea"
                label="Message the coach"
                rows="1"
                maxlength="1000"
                placeholder="Message the coach"
                class="composer-input"
                disabled={@state.coach_busy?}
              />
              <div class="composer-bar">
                <button
                  id="home-coach-message-send"
                  type="submit"
                  class="composer-send"
                  disabled={@state.coach_busy?}
                  aria-label="Send"
                  title="Send"
                >
                  <span class="composer-send-dot" aria-hidden="true">
                    <.icon name="hero-arrow-up-mini" class="size-5" />
                  </span>
                </button>
              </div>
            </.form>
          </div>
        </div>
        <p id="home-coach-reply" role="status" class="coach-guidance-status">
          {@state.coach_reply}
        </p>
        <p id="home-coach-status" role="status" class="coach-guidance-status">
          {@state.coach_status}
        </p>
      <% end %>
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
      <.memory_sheet :if={Map.get(@state, :coach_memory_open?, false)} state={@state} />
      <div :if={coach?(@state)} class="chat-dock-spacer" aria-hidden="true"></div>
    </section>
    """
  end

  # Changes whenever the conversation moves, so the dock brings the newest line into view.
  defp coach_version(state),
    do: "#{length(Map.get(state, :coach_thread, []))}:#{state.coach_busy?}"

  @doc """
  Whether Home has a coach section: always with the app's coach; without it, only once
  there is something from Claude to read (a note, or a change to the memory).
  """
  def shown?(state),
    do:
      coach?(state) or not is_nil(state.progress_summary) or
        Map.get(state, :coach_memory_changes, []) != []

  defp coach?(state), do: BurpeeTrainer.Coach.enabled?(state.current_scope)

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

  defp week_when(%{status: :left, duration_sec: sec}, _timezone), do: "#{div(sec, 60)} min to go"

  defp memory_verb(:noted), do: "Noted: "
  defp memory_verb(:updated), do: "Updated: "
  defp memory_verb(:forgot), do: "Forgot: "

  defp memory_count(state),
    do: state |> Map.get(:coach_memory, []) |> Enum.map(&length(&1.entries)) |> Enum.sum()

  attr(:state, :map, required: true)

  defp memory_button(assigns) do
    ~H"""
    <button
      id="home-coach-memory-toggle"
      type="button"
      class="coach-memory-toggle"
      phx-click="coach_memory_toggle"
      aria-haspopup="dialog"
      aria-expanded={to_string(Map.get(@state, :coach_memory_open?, false))}
      aria-label="What the coach remembers"
      title="What the coach remembers"
    >
      <.icon name="hero-bookmark" class="size-5" />
    </button>
    """
  end

  attr(:state, :map, required: true)

  # What the coach remembers, as a sheet over the coach: who the athlete is, then its
  # notes on coaching them, each part with how full it is. An entry can be removed.
  defp memory_sheet(assigns) do
    ~H"""
    <div id="home-coach-memory-backdrop" class="home-sheet-backdrop" phx-click="coach_memory_close">
    </div>
    <div
      id="home-coach-memory"
      class="home-sheet coach-memory-sheet"
      role="dialog"
      aria-modal="true"
      aria-label="What the coach remembers"
      phx-window-keydown="coach_memory_close"
      phx-key="Escape"
      phx-mounted={JS.focus()}
      tabindex="-1"
      data-no-swipe
    >
      <span class="home-sheet-grip" aria-hidden="true"></span>
      <section
        :for={part <- @state.coach_memory}
        id={"home-coach-memory-#{part.store}"}
        class="coach-memory-part"
      >
        <h3 class="coach-memory-heading">
          <span>{if(part.store == "user", do: "Profile", else: "Notes")}</span>
          <span class="coach-memory-usage">{part.percent}%</span>
        </h3>
        <p :if={part.entries == []} class="coach-memory-empty">Nothing yet.</p>
        <ul :if={part.entries != []} class="coach-memory-entries">
          <li :for={entry <- part.entries} id={"home-coach-memory-entry-#{entry.id}"}>
            <span>{entry.text}</span>
            <button
              id={"home-coach-memory-forget-#{entry.id}"}
              type="button"
              class="coach-memory-forget"
              phx-click="coach_memory_forget"
              phx-value-id={entry.id}
              aria-label={"Forget: #{entry.text}"}
              title="Forget"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </li>
        </ul>
      </section>
    </div>
    """
  end
end
