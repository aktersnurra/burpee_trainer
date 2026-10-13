defmodule BurpeeTrainerWeb.HistoryScreen do
  @moduledoc "Saved workout history, its period controls, inspection, and deletion flows."

  use BurpeeTrainerWeb, :html
  import Phoenix.LiveView

  alias BurpeeTrainer.{Goals, History, Workouts}
  alias BurpeeTrainerWeb.{HomeHistoryComponents, HomeWorkoutComponents}

  def initialize(socket) do
    socket
    |> assign_new(:home_now, fn -> fn -> DateTime.utc_now(:second) end end)
    |> assign(
      history_open?: true,
      history_period: "twelve_weeks",
      history_show_sessions?: false,
      history_weeks: [],
      history_streak: 0,
      history_week_start: nil,
      history_week_days: [],
      history_session_return_to: "#home-history-heading",
      history_selected_id: nil,
      history_selected_session: nil,
      history_selected_insight: nil,
      history_confirm_delete?: false,
      history_error: nil,
      history_cursor: nil,
      history_has_more?: false,
      history_empty?: true,
      history_expanded: MapSet.new(),
      history_points: %{six_count: [], navy_seal: []},
      history_summary: History.summary([]),
      history_loaded_ids: [],
      history_loaded_count: 0,
      history_available?: false,
      history_headline: %{headline: %{kind: :none}, others: []},
      history_next_dismissed?: false
    )
    |> stream_configure(:history_sessions, dom_id: &"home-history-session-#{&1.id}")
    |> stream(:history_sessions, [])
  end

  def open(socket) do
    socket
    |> assign(history_open?: true, history_show_sessions?: false)
    |> load_history(true)
  end

  def refresh(socket, now), do: load_history(socket, true, now, true)

  def handle_event("close_history", _, socket) do
    {:noreply,
     socket
     |> assign(
       history_show_sessions?: false,
       history_selected_id: nil,
       history_selected_session: nil,
       history_confirm_delete?: false,
       history_expanded: MapSet.new()
     )
     |> push_patch(to: ~p"/")}
  end

  def handle_event("history_period", %{"period" => period}, socket)
      when period in ["twelve_weeks", "year", "all"] do
    {:noreply,
     socket
     |> assign(
       history_period: period,
       history_week_start: nil,
       history_week_days: [],
       history_expanded: MapSet.new(),
       history_selected_id: nil,
       history_selected_session: nil
     )
     |> load_history(true)}
  end

  def handle_event("history_density_mode", %{"mode" => mode}, socket)
      when mode in ["chart", "sessions"] do
    {:noreply, assign(socket, :history_show_sessions?, mode == "sessions")}
  end

  def handle_event("history_more", _, socket) do
    if socket.assigns.history_has_more?,
      do: {:noreply, load_history(socket, false)},
      else: {:noreply, socket}
  end

  def handle_event("history_week", %{"start" => raw}, socket) when is_binary(raw) do
    a = socket.assigns

    with true <- is_nil(a.history_error),
         {:ok, date} <- Date.from_iso8601(raw),
         %{start: ^date} <- Enum.find(a.history_weeks, &(&1.start == date)),
         {:ok, days} <-
           History.week_days(
             Workouts.list_sessions(a.current_scope),
             a.current_scope.user,
             a.home_now.(),
             date
           ) do
      {:noreply, assign(socket, history_week_start: date, history_week_days: days)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("history_week_back", _, socket),
    do: {:noreply, assign(socket, history_week_start: nil, history_week_days: [])}

  def handle_event("history_session", %{"id" => raw} = params, socket) when is_binary(raw) do
    a = socket.assigns

    with {id, ""} when id > 0 <- Integer.parse(raw),
         %{state: :completed} = session <- Workouts.get_session(a.current_scope, id),
         {:ok, [_]} <-
           History.filter_sessions(
             [session],
             a.current_scope.user,
             a.home_now.(),
             a.history_period
           ) do
      expanded =
        if MapSet.member?(a.history_expanded, id),
          do: MapSet.delete(a.history_expanded, id),
          else: MapSet.put(a.history_expanded, id)

      ids = Enum.uniq(a.history_loaded_ids ++ [id])
      selected? = MapSet.member?(expanded, id)

      {:noreply,
       socket
       |> assign(
         history_expanded: expanded,
         history_loaded_ids: ids,
         history_selected_id: if(selected?, do: id),
         history_selected_session: if(selected?, do: session),
         history_selected_insight:
           if(selected?, do: BurpeeTrainer.Insights.for_session(a.current_scope, id)),
         history_session_return_to:
           if(params["source"] == "point",
             do: "#home-history-point-#{id}",
             else: "#home-history-inspect-#{id}"
           ),
         history_confirm_delete?: false,
         # A point on the chart opens its session in place, in the list.
         history_show_sessions?: a.history_show_sessions? or params["source"] == "point"
       )
       |> restream_history_rows(nil, a.history_loaded_ids)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("history_close_session", _, socket) do
    a = socket.assigns

    {:noreply,
     socket
     |> assign(
       history_selected_id: nil,
       history_selected_session: nil,
       history_confirm_delete?: false,
       history_expanded: MapSet.delete(a.history_expanded, a.history_selected_id)
     )
     |> restream_history_rows(nil, a.history_loaded_ids)}
  end

  # The detail lives in a stream row, so a change to it re-inserts the rows.
  def handle_event("history_confirm_delete", _, socket) do
    if socket.assigns.history_selected_id,
      do:
        {:noreply,
         socket
         |> assign(history_confirm_delete?: true)
         |> restream_history_rows(nil, socket.assigns.history_loaded_ids)},
      else: {:noreply, socket}
  end

  def handle_event("history_cancel_delete", _, socket),
    do:
      {:noreply,
       socket
       |> assign(history_confirm_delete?: false)
       |> restream_history_rows(nil, socket.assigns.history_loaded_ids)}

  def handle_event("history_delete_session", _, socket) do
    a = socket.assigns

    with true <- a.history_confirm_delete?,
         id when is_integer(id) <- a.history_selected_id,
         %{state: :completed} = session <- Workouts.get_session(a.current_scope, id),
         {:ok, [_]} <-
           History.filter_sessions(
             [session],
             a.current_scope.user,
             a.home_now.(),
             a.history_period
           ),
         {:ok, _} <- Workouts.delete_session(a.current_scope, session) do
      {:noreply,
       socket
       |> assign(
         history_selected_id: nil,
         history_selected_session: nil,
         history_confirm_delete?: false,
         history_expanded: MapSet.new()
       )
       |> load_history(true)}
    else
      _ ->
        {:noreply,
         assign(socket,
           history_error: "Couldn’t delete this session. Reload Home to try again.",
           history_session_return_to: "#home-history-heading"
         )
         |> restream_history_rows(nil, socket.assigns.history_loaded_ids)}
    end
  end

  def handle_event("progress_set_goal", _, socket) do
    a = socket.assigns

    with %{next: next} <- a.history_headline.headline,
         {:ok, %{"goal_id" => id}} <-
           BurpeeTrainer.Coach.Tools.ProposeGoal.call(
             a.current_scope,
             %{
               "burpee_type" => Atom.to_string(next.burpee_type),
               "burpee_count_target" => next.burpee_count_target,
               "duration_sec_target" => next.duration_sec_target,
               "date_target" => Date.to_iso8601(next.date_target)
             },
             %{}
           ),
         {:ok, _goal} <- Goals.confirm(a.current_scope, id) do
      {:noreply, load_history(socket, false)}
    else
      _ -> {:noreply, assign(socket, history_next_dismissed?: true)}
    end
  end

  def handle_event("progress_not_now", _, socket),
    do: {:noreply, assign(socket, history_next_dismissed?: true)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load_history(socket, reset?, now \\ nil, retain_loaded? \\ false) do
    a = socket.assigns
    now = now || a.home_now.()
    socket = assign(socket, :history_snapshot_now, now)
    cursor = if reset?, do: nil, else: a.history_cursor

    with {:ok, rows, next, more?} <-
           History.page(a.current_scope, now, a.history_period, cursor) do
      {points, summary} =
        if reset? do
          history_sessions =
            Map.new([:six_count, :navy_seal], fn type ->
              {:ok, sessions} =
                History.filter_sessions(
                  Workouts.list_sessions_for_chart(a.current_scope, type),
                  a.current_scope.user,
                  now,
                  a.history_period
                )

              {type, sessions}
            end)

          points =
            Map.new(history_sessions, fn {type, sessions} ->
              {type, History.points(sessions)}
            end)

          summary =
            history_sessions
            |> Map.values()
            |> List.flatten()
            |> Enum.uniq_by(& &1.id)
            |> History.summary()

          {points, summary}
        else
          {a.history_points, a.history_summary}
        end

      ids =
        Enum.uniq(
          if(reset? and not retain_loaded?, do: [], else: a.history_loaded_ids) ++
            Enum.map(rows, & &1.id)
        )

      all_sessions = Workouts.list_sessions(a.current_scope)

      {:ok, available_sessions} =
        History.filter_sessions(all_sessions, a.current_scope.user, now, "all")

      history_available? = available_sessions != []
      {:ok, weeks} = History.weeks(all_sessions, a.current_scope.user, now, a.history_period)
      weeks = from_first_trained_week(weeks)
      {:ok, all_weeks} = History.weeks(all_sessions, a.current_scope.user, now, "all")

      selected_week =
        if Enum.any?(weeks, &(&1.start == a.history_week_start)),
          do: a.history_week_start,
          else: nil

      days =
        if selected_week do
          {:ok, days} = History.week_days(all_sessions, a.current_scope.user, now, selected_week)
          days
        else
          []
        end

      socket
      |> assign(
        history_available?: history_available?,
        history_headline: headline(a.current_scope, all_sessions, now),
        history_weeks: weeks,
        history_week_start: selected_week,
        history_week_days: days,
        history_streak: History.streak(all_weeks),
        history_error: nil,
        history_cursor: next,
        history_has_more?: more?,
        history_empty?: ids == [],
        history_points: points,
        history_summary: summary,
        history_loaded_ids: ids,
        history_loaded_count: length(ids)
      )
      |> restream_history_rows(now, if(retain_loaded?, do: a.history_loaded_ids))
    else
      {:error, _} ->
        socket
        |> assign(
          history_error: "Progress is unavailable. Reload Home to try again.",
          history_session_return_to: "#home-history-heading",
          history_cursor: nil,
          history_has_more?: false,
          history_empty?: true,
          history_loaded_ids: [],
          history_loaded_count: 0,
          history_weeks: [],
          history_week_start: nil,
          history_week_days: [],
          history_streak: 0,
          history_points: %{six_count: [], navy_seal: []},
          history_summary: History.summary([])
        )
        |> stream(:history_sessions, [], reset: true)
    end
  end

  # Retain only explicitly displayed IDs. Scoped re-reads keep inspected older points
  # in compound-key order as intervening pages arrive, without changing the cursor.
  defp restream_history_rows(socket, now, previous_ids) do
    a = socket.assigns
    now = now || a.home_now.()

    rows =
      a.history_loaded_ids
      |> Enum.map(&Workouts.get_session(a.current_scope, &1))
      |> Enum.filter(&match?(%{state: :completed}, &1))

    {:ok, rows} =
      History.filter_sessions(rows, a.current_scope.user, now, a.history_period)

    rows = Enum.sort_by(rows, &{DateTime.to_unix(&1.completed_at, :microsecond), &1.id}, :desc)

    ids = Enum.map(rows, & &1.id)

    socket =
      assign(socket,
        history_loaded_ids: ids,
        history_loaded_count: length(rows),
        history_empty?: rows == []
      )

    if is_list(previous_ids) do
      # A stream reset detaches even retained buttons. Incremental reconciliation
      # deletes only expired rows and inserts new rows at their compound-key rank.
      socket =
        Enum.reduce(previous_ids -- ids, socket, fn id, acc ->
          stream_delete_by_dom_id(acc, :history_sessions, "home-history-session-#{id}")
        end)

      rows
      |> Enum.with_index()
      |> Enum.reduce(socket, fn {row, index}, acc ->
        stream_insert(acc, :history_sessions, row, at: index)
      end)
    else
      stream(socket, :history_sessions, rows, reset: true)
    end
  end

  # The grid starts at the first week with training, never a row of empty weeks; this
  # week stays, as it is the one in progress.
  defp from_first_trained_week([]), do: []

  defp from_first_trained_week(weeks) do
    {earlier, [current]} = Enum.split(weeks, -1)
    Enum.drop_while(earlier, &(&1.seconds == 0)) ++ [current]
  end

  @doc "What leads Progress for `scope` at `now`; nothing when the owner's calendar is unknown."
  def headline(scope, sessions, now) do
    case BurpeeTrainer.UserTime.context(scope.user, now) do
      {:ok, context} ->
        BurpeeTrainer.ProgressHeadline.pick(
          Goals.list(scope),
          sessions,
          context.date,
          context.timezone
        )

      {:error, _reason} ->
        %{headline: %{kind: :none}, others: []}
    end
  end

  def screen(assigns) do
    ~H"""
    <main
      id="history-page"
      class="mx-auto w-full max-w-3xl px-5 py-10 sm:px-8 sm:py-16"
      phx-window-keydown={
        cond do
          is_nil(@history_selected_session) -> "close_history"
          @history_confirm_delete? -> "history_cancel_delete"
          true -> "history_close_session"
        end
      }
      phx-key="Escape"
    >
      <div class="adaptive-home">
        <%!-- The week's progress stays on top of every screen; here it leads back Home. --%>
        <div id="history-progress" class="relative min-h-11">
          <HomeWorkoutComponents.week_progress :if={@slot} slot={@slot} />
          <button
            id="home-history-close"
            type="button"
            class="absolute inset-0 min-h-11 rounded-sm focus-visible:outline-2 focus-visible:outline-offset-4"
            phx-click="close_history"
            aria-label="Back to Home"
          >
            <span class="sr-only">Back to Home</span>
          </button>
        </div>
        <HomeHistoryComponents.panel state={assigns} />
      </div>
    </main>
    """
  end
end
