defmodule BurpeeTrainerWeb.HomeCoachComponents do
  @moduledoc """
  The coach summary, the coach on Home once today's training is done, and the Coach page
  (`/coach`) with what the coach remembers in a sheet.
  """

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

  # The coach is a section of Home, not a card: this week's window in Progress's rows, then
  # the conversation as a chat, its opener first, with what it noted or forgot about you as
  # quiet lines between exchanges. The bookmark leads to the Coach page.
  # See docs/specs/2026-11-06-light-screens-design.md.
  def panel(assigns) do
    ~H"""
    <section id="home-coach-panel" class="home-coach-panel" aria-label="Coach">
      <.week_rows state={@state} />
      <div class="coach-chat-head">
        <span>Coach</span>
        <.link
          :if={coach?(@state)}
          id="home-coach-open"
          patch={~p"/coach"}
          data-vt="forward"
          class="coach-page-action"
          aria-label="Open the coach"
          title="Coach"
          phx-mounted={
            Map.get(@state, :home_focus_from) == :coach && JS.focus(to: "#home-coach-open")
          }
        >
          <.icon name="hero-bookmark" class="size-5" />
        </.link>
      </div>
      <.conversation state={@state} field={:text} />
      <.composer :if={coach?(@state)} state={@state} />
      <.goals state={@state} />
      <div :if={coach?(@state)} class="chat-dock-spacer" aria-hidden="true"></div>
    </section>
    """
  end

  attr(:state, :map, required: true)

  @doc """
  The Coach page: Back, "Coach" and the memory bookmark on top, then the week's sessions, the
  chat and the box (no week bar under the header). Arriving from Progress, the look back is the chat's first message.
  """
  def page(assigns) do
    ~H"""
    <main id="coach-page" class="mx-auto w-full max-w-3xl">
      <div class="adaptive-home coach-page">
        <header class="coach-page-top">
          <.link
            id="coach-back"
            patch={if(@state.coach_from == :progress, do: ~p"/progress", else: ~p"/")}
            data-vt="back"
            class="coach-page-action"
            aria-label="Back"
            title="Back"
          >
            <.icon name="hero-chevron-left" class="size-5" />
          </.link>
          <%!-- Focus lands on the title when the page opens, as on Progress, for screen readers. --%>
          <h1
            id="coach-page-heading"
            class="coach-page-title"
            tabindex="-1"
            phx-mounted={JS.focus(to: "#coach-page-heading")}
          >
            Coach
          </h1>
          <button
            id="coach-memory-open"
            type="button"
            class="coach-page-action"
            phx-click="coach_memory_toggle"
            aria-haspopup="dialog"
            aria-expanded={to_string(Map.get(@state, :coach_memory_open?, false))}
            aria-controls="coach-memory"
            aria-label="What the coach remembers"
            title="What the coach remembers"
          >
            <.icon name="hero-bookmark" class="size-5" />
          </button>
        </header>
        <section id="coach-page-body" aria-labelledby="coach-page-heading">
          <.week_rows state={@state} />
          <.conversation
            state={@state}
            field={if(@state.coach_from == :progress, do: :review, else: :text)}
          />
          <.composer state={@state} />
          <.goals state={@state} />
          <div class="chat-dock-spacer" aria-hidden="true"></div>
        </section>
      </div>
      <.memory_sheet :if={Map.get(@state, :coach_memory_open?, false)} state={@state} />
    </main>
    """
  end

  attr(:state, :map, required: true)

  # This week's window as Progress's rows: what is done, then what is left, muted.
  defp week_rows(assigns) do
    ~H"""
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
    """
  end

  attr(:state, :map, required: true)
  attr(:field, :atom, required: true, values: [:text, :review])

  # The conversation as a chat: the coach's opener first, then this week's exchanges, you on
  # the right and the coach on the left, what it noted between. Kept across reloads.
  defp conversation(assigns) do
    assigns = assign(assigns, :field, opener_field(assigns.state, assigns.field))

    ~H"""
    <div class="coach-chat">
      <p
        :if={opener?(@state)}
        id="home-coach-note"
        class="coach-exchange-coach coach-opener"
      >
        <.summary_body
          :if={@state.progress_summary || @state.progress_summary_loading?}
          summary={@state.progress_summary}
          loading?={@state.progress_summary_loading?}
          field={@field}
        />
        <span :if={
          coach?(@state) and is_nil(@state.progress_summary) and
            not @state.progress_summary_loading?
        }>
          Tell me what you're training for, or how the last session felt.
        </span>
      </p>
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
    </div>
    """
  end

  attr(:state, :map, required: true)

  # Talking to the app's coach needs it; without it the coach is Claude, and Home shows only
  # what Claude left. The box rides above the keyboard, as in the design chat (see the
  # ChatDock hook).
  defp composer(assigns) do
    ~H"""
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
    """
  end

  attr(:state, :map, required: true)

  # Goals the coach proposed, waiting on the owner.
  defp goals(assigns) do
    ~H"""
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

  defp opener?(state),
    do: coach?(state) or not is_nil(state.progress_summary) or state.progress_summary_loading?

  # From Progress the look back opens the chat; a summary without one opens with its note.
  defp opener_field(%{progress_summary: %{review: review}}, :review)
       when is_binary(review) and review != "",
       do: :review

  defp opener_field(_state, _field), do: :text

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

  # Closing returns focus to the bookmark that opened the sheet, however it closes.
  defp close_memory,
    do: JS.push("coach_memory_close") |> JS.focus(to: "#coach-memory-open")

  attr(:state, :map, required: true)

  # What the coach remembers, in the workout picker's bottom sheet: who the athlete is, then
  # its notes on coaching them, each part with how full it is. A line the coach changed this
  # week is marked; a line can be forgotten here, and changed by telling the coach.
  defp memory_sheet(assigns) do
    assigns = assign(assigns, :updated, updated_texts(assigns.state))

    ~H"""
    <div
      id="coach-memory-backdrop"
      class="home-sheet-backdrop"
      phx-click={close_memory()}
      phx-remove={JS.transition("coach-sheet-fade-out", time: 360)}
    >
    </div>
    <div
      id="coach-memory"
      class="home-sheet coach-memory-sheet"
      role="dialog"
      aria-modal="true"
      aria-labelledby="coach-memory-title"
      phx-hook="SheetDrag"
      data-close="#coach-memory-close"
      data-backdrop="#coach-memory-backdrop"
      phx-window-keydown={close_memory()}
      phx-key="Escape"
      phx-mounted={JS.focus(to: "#coach-memory-close")}
      phx-remove={JS.transition("coach-sheet-leave", time: 360)}
      data-no-swipe
    >
      <.focus_wrap id="coach-memory-focus">
        <div class="home-sheet-grip" aria-hidden="true"></div>
        <header class="coach-memory-top">
          <button
            id="coach-memory-close"
            type="button"
            class="coach-page-action"
            phx-click={close_memory()}
            aria-label="Close"
            title="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
          <h2 id="coach-memory-title">What I remember</h2>
        </header>
        <section
          :for={part <- @state.coach_memory}
          id={"coach-memory-#{part.store}"}
          class="coach-memory-part"
          aria-labelledby={"coach-memory-#{part.store}-heading"}
        >
          <h3 class="coach-memory-heading">
            <span id={"coach-memory-#{part.store}-heading"}>{part_name(part.store)}</span>
            <span
              class="coach-memory-usage"
              role="meter"
              aria-valuemin="0"
              aria-valuemax="100"
              aria-valuenow={part.percent}
              aria-label={"#{part_name(part.store)}, #{part.percent}% full"}
              title={"#{part.percent}% full"}
            >
              <span style={"width: #{min(part.percent, 100)}%"}></span>
            </span>
          </h3>
          <p :if={part.entries == []} class="coach-memory-empty">Nothing yet.</p>
          <ul :if={part.entries != []} class="coach-memory-entries">
            <li
              :for={entry <- part.entries}
              id={"coach-memory-entry-#{entry.id}"}
              data-changed={to_string(entry.text in @updated)}
            >
              <span>{entry.text}</span>
              <button
                id={"coach-memory-forget-#{entry.id}"}
                type="button"
                class="coach-memory-forget"
                phx-click={
                  JS.push("coach_memory_forget", value: %{id: entry.id})
                  |> JS.focus(to: "#coach-memory-close")
                }
                aria-label={"Forget: #{entry.text}"}
                title="Forget"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </li>
          </ul>
        </section>
        <p class="coach-memory-foot">To change a line, tell the coach.</p>
      </.focus_wrap>
    </div>
    """
  end

  defp part_name("user"), do: "About you"
  defp part_name(_memory), do: "Coaching notes"

  # The lines the coach rewrote this week; a line only added reads as "Noted" in the chat.
  defp updated_texts(state),
    do:
      for(
        %{kind: :updated, text: text} <- Map.get(state, :coach_memory_changes, []),
        into: MapSet.new(),
        do: text
      )
end
