defmodule BurpeeTrainerWeb.SessionAnalysisLive do
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainerWeb.Fmt

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user
    session = Workouts.get_session!(user, String.to_integer(id))

    if tracked?(session) do
      {:ok,
       socket
       |> assign(:session, session)
       |> assign(:analytics, analytics(session))}
    else
      {:ok, push_navigate(socket, to: ~p"/stats")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:stats}>
      <div class="space-y-5 pb-20">
        <div class="flex items-center justify-between">
          <.link navigate={~p"/stats"} class="text-sm text-base-content/50 hover:text-base-content">
            ← Stats
          </.link>
          <span class="rounded-full border border-primary/30 px-2 py-0.5 text-[10px] uppercase tracking-wide text-primary">
            Tracked
          </span>
        </div>

        <section class="rounded-[10px] bg-base-300 p-5 space-y-4">
          <div class="space-y-1">
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/40">
              Session analysis
            </p>
            <div class="flex items-end justify-between gap-4">
              <div>
                <p class="text-4xl font-bold tabular-nums">{@session.burpee_count_actual}</p>
                <p class="text-sm text-base-content/50">{Fmt.burpee_type(@session.burpee_type)}</p>
              </div>
              <div class="text-right">
                <p class="text-lg font-semibold tabular-nums">
                  {Fmt.duration_sec(@session.duration_sec_actual)}
                </p>
                <p class="text-xs text-base-content/40">
                  {Calendar.strftime(DateTime.to_date(@session.inserted_at), "%d %b %Y")}
                </p>
              </div>
            </div>
          </div>
        </section>

        <section class="grid grid-cols-2 gap-3">
          <.metric_card label="Avg pace" value={format_seconds(@analytics.avg_pace_sec)} />
          <.metric_card
            label="Consistency"
            value={"#{round((@session.pace_consistency || 0) * 100)}%"}
          />
          <.metric_card label="Fastest rep" value={format_seconds(@analytics.fastest_sec)} />
          <.metric_card label="Slowest rep" value={format_seconds(@analytics.slowest_sec)} />
          <.metric_card label="Best window" value={format_seconds(@analytics.best_window_sec)} />
          <.metric_card label="Pace drift" value={format_percent(@analytics.drift)} />
        </section>

        <section class="rounded-[10px] bg-base-300 p-5 space-y-4">
          <div>
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/40">
              Pace by rep
            </p>
            <p class="text-sm text-base-content/50">Seconds between detected reps</p>
          </div>

          <div class="space-y-2">
            <%= for point <- @analytics.points do %>
              <div class="grid grid-cols-[2.5rem_1fr_4rem] items-center gap-3">
                <span class="text-xs text-base-content/40 tabular-nums">#{point.rep}</span>
                <div class="h-2 rounded-full bg-base-border overflow-hidden">
                  <div class="h-full rounded-full bg-primary" style={"width: #{point.width}%"}></div>
                </div>
                <span class="text-right text-xs tabular-nums text-base-content/60">
                  {format_seconds(point.seconds)}
                </span>
              </div>
            <% end %>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp metric_card(assigns) do
    ~H"""
    <div class="rounded-[10px] bg-base-300 p-4">
      <p class="text-[10px] uppercase tracking-widest text-base-content/40">{@label}</p>
      <p class="mt-1 text-2xl font-bold tabular-nums">{@value}</p>
    </div>
    """
  end

  defp tracked?(%{capture_mode: :tracked, cadence_ms: cadence}) when is_binary(cadence), do: true
  defp tracked?(_session), do: false

  defp analytics(session) do
    cadence = Jason.decode!(session.cadence_ms)
    intervals = intervals(cadence)
    interval_secs = Enum.map(intervals, &(&1 / 1000))
    max_interval = Enum.max(interval_secs, fn -> 1 end)

    %{
      avg_pace_sec: avg_pace(session),
      fastest_sec: Enum.min(interval_secs, fn -> nil end),
      slowest_sec: Enum.max(interval_secs, fn -> nil end),
      best_window_sec: best_window(interval_secs, 3),
      drift: drift(interval_secs),
      points:
        interval_secs
        |> Enum.with_index(2)
        |> Enum.map(fn {seconds, rep} ->
          %{rep: rep, seconds: seconds, width: max(round(seconds / max_interval * 100), 4)}
        end)
    }
  end

  defp intervals(cadence) do
    cadence
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> b - a end)
  end

  defp avg_pace(%{burpee_count_actual: reps, duration_sec_actual: duration})
       when is_integer(reps) and reps > 0 and is_integer(duration) do
    duration / reps
  end

  defp avg_pace(_session), do: nil

  defp best_window(interval_secs, size) when length(interval_secs) >= size do
    interval_secs
    |> Enum.chunk_every(size, 1, :discard)
    |> Enum.map(&(Enum.sum(&1) / length(&1)))
    |> Enum.min()
  end

  defp best_window(interval_secs, _size) do
    case interval_secs do
      [] -> nil
      values -> Enum.sum(values) / length(values)
    end
  end

  defp drift(interval_secs) when length(interval_secs) >= 2 do
    half = max(div(length(interval_secs), 2), 1)
    first = interval_secs |> Enum.take(half) |> average()
    last = interval_secs |> Enum.take(-half) |> average()

    if first > 0, do: (last - first) / first, else: 0.0
  end

  defp drift(_interval_secs), do: 0.0

  defp average(values), do: Enum.sum(values) / length(values)

  defp format_seconds(nil), do: "—"
  defp format_seconds(seconds), do: "#{:erlang.float_to_binary(seconds / 1, decimals: 1)}s"

  defp format_percent(value) when value > 0,
    do: "+#{round(value * 100)}%"

  defp format_percent(value), do: "#{round(value * 100)}%"
end
