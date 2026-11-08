defmodule BurpeeTrainerWeb.HistoryScreen do
  @moduledoc "Progress: twelve weeks on one chart, a session opened from its point, and deleting it."

  use BurpeeTrainerWeb, :html
  import Phoenix.LiveView

  alias BurpeeTrainer.{Goals, History, Workouts}
  alias BurpeeTrainerWeb.{HomeHistoryComponents, HomeWorkoutComponents}

  # The chart, and what can be opened from it, reads the last twelve weeks.
  @period "twelve_weeks"

  def initialize(socket) do
    socket
    |> assign_new(:home_now, fn -> fn -> DateTime.utc_now(:second) end end)
    |> assign(
      history_open?: true,
      history_weeks: [],
      history_grid_weeks: [],
      history_streak: 0,
      history_selected_session: nil,
      history_confirm_delete?: false,
      history_error: nil,
      history_empty?: true,
      history_points: %{six_count: [], navy_seal: []},
      history_available?: false,
      history_gauges: gauges_none()
    )
  end

  def open(socket), do: socket |> assign(history_open?: true) |> load_history()

  # At a day boundary an opened session stays open while it is still in the twelve weeks.
  def refresh(socket, now) do
    selected =
      with %{id: id} <- socket.assigns.history_selected_session, do: in_period(socket, id, now)

    socket
    |> assign(
      history_selected_session: selected,
      history_confirm_delete?: socket.assigns.history_confirm_delete? and not is_nil(selected)
    )
    |> load_history(now)
  end

  def handle_event("close_history", _, socket) do
    {:noreply,
     socket
     |> assign(history_selected_session: nil, history_confirm_delete?: false)
     |> push_patch(to: ~p"/")}
  end

  # A point opens its session under the chart; the same point, or the session, closes it.
  def handle_event("history_session", %{"id" => raw}, socket) when is_binary(raw) do
    with {id, ""} when id > 0 <- Integer.parse(raw),
         %{state: :completed} = session <- in_period(socket, id, socket.assigns.home_now.()) do
      selected =
        if match?(%{id: ^id}, socket.assigns.history_selected_session), do: nil, else: session

      {:noreply,
       assign(socket, history_selected_session: selected, history_confirm_delete?: false)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("history_close_session", _, socket),
    do: {:noreply, assign(socket, history_selected_session: nil, history_confirm_delete?: false)}

  def handle_event("history_confirm_delete", _, socket),
    do:
      {:noreply,
       assign(socket,
         history_confirm_delete?: not is_nil(socket.assigns.history_selected_session)
       )}

  def handle_event("history_cancel_delete", _, socket),
    do: {:noreply, assign(socket, history_confirm_delete?: false)}

  def handle_event("history_delete_session", _, socket) do
    a = socket.assigns

    with true <- a.history_confirm_delete?,
         %{id: id} <- a.history_selected_session,
         %{state: :completed} = session <- in_period(socket, id, a.home_now.()),
         {:ok, _} <- Workouts.delete_session(a.current_scope, session) do
      {:noreply,
       socket
       |> assign(history_selected_session: nil, history_confirm_delete?: false)
       |> load_history()}
    else
      _ ->
        {:noreply,
         assign(socket,
           history_error: "Couldn’t delete this session. Reload Home to try again."
         )}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The owner's completed session `id`, when it falls in the chart's twelve weeks at `now`.
  defp in_period(socket, id, now) do
    scope = socket.assigns.current_scope

    with %{state: :completed} = session <- Workouts.get_session(scope, id),
         {:ok, [_]} <- History.filter_sessions([session], scope.user, now, @period) do
      session
    else
      _ -> nil
    end
  end

  defp load_history(socket, now \\ nil) do
    a = socket.assigns
    now = now || a.home_now.()
    socket = assign(socket, :history_snapshot_now, now)
    user = a.current_scope.user

    with {:ok, _} <- History.filter_sessions([], user, now, @period) do
      points =
        Map.new([:six_count, :navy_seal], fn type ->
          {:ok, sessions} =
            History.filter_sessions(
              Workouts.list_sessions_for_chart(a.current_scope, type),
              user,
              now,
              @period
            )

          {type, History.points(sessions)}
        end)

      all_sessions = Workouts.list_sessions(a.current_scope)
      {:ok, available_sessions} = History.filter_sessions(all_sessions, user, now, "all")
      {:ok, in_period} = History.filter_sessions(all_sessions, user, now, @period)
      {:ok, weeks} = History.weeks(all_sessions, user, now, @period)
      {:ok, all_weeks} = History.weeks(all_sessions, user, now, "all")
      {:ok, year_weeks} = History.weeks(all_sessions, user, now, "year")

      assign(socket,
        history_available?: available_sessions != [],
        history_gauges: gauges(a.current_scope, all_sessions, now),
        history_weeks: from_first_trained_week(weeks),
        history_grid_weeks: Enum.take(year_weeks, -HomeHistoryComponents.grid_weeks()),
        history_streak: History.streak(all_weeks),
        history_error: nil,
        history_empty?: in_period == [],
        history_points: points
      )
    else
      {:error, _} ->
        assign(socket,
          history_error: "Progress is unavailable. Reload Home to try again.",
          history_empty?: true,
          history_weeks: [],
          history_grid_weeks: [],
          history_streak: 0,
          history_points: %{six_count: [], navy_seal: []}
        )
    end
  end

  # The chart starts at the first week with training, never a stretch of empty weeks; this
  # week stays, as it is the one in progress.
  defp from_first_trained_week([]), do: []

  defp from_first_trained_week(weeks) do
    {earlier, [current]} = Enum.split(weeks, -1)
    Enum.drop_while(earlier, &(&1.seconds == 0)) ++ [current]
  end

  @doc "Each burpee type's gauge for `scope` at `now`; empty ones when the calendar is unknown."
  def gauges(scope, sessions, now) do
    case BurpeeTrainer.UserTime.context(scope.user, now) do
      {:ok, context} ->
        BurpeeTrainer.ProgressGauges.for_types(
          Goals.list(scope),
          sessions,
          context.date,
          context.timezone
        )

      {:error, _reason} ->
        gauges_none()
    end
  end

  defp gauges_none,
    do: [%{kind: :none, burpee_type: :six_count}, %{kind: :none, burpee_type: :navy_seal}]

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
            data-vt="back"
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
