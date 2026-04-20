defmodule BurpeeTrainerWeb.HistoryLive do
  @moduledoc """
  Session history — chart with per-type series and optional goal + trend
  overlays, PR panel, and a sortable session table.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Goals, Progression, Workouts}
  alias BurpeeTrainerWeb.Fmt

  @series_styles %{
    six_count: %{color: "rgb(59, 130, 246)", background: "rgba(59, 130, 246, 0.1)"},
    navy_seal: %{color: "rgb(249, 115, 22)", background: "rgba(249, 115, 22, 0.1)"}
  }

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    sessions = Workouts.list_sessions(user)
    active_goals = Goals.list_active_goals(user)

    {:ok,
     socket
     |> assign(:sessions, sessions)
     |> assign(:prs, pr_panel(sessions))
     |> assign(:chart, chart_data(sessions, active_goals, user))}
  end

  defp pr_panel(sessions) do
    for type <- [:six_count, :navy_seal], into: %{} do
      typed = Enum.filter(sessions, &(&1.burpee_type == type))
      {type, pr_panel_for_type(typed)}
    end
  end

  defp pr_panel_for_type([]), do: nil

  defp pr_panel_for_type(sessions) do
    burpees_max = Enum.max_by(sessions, & &1.burpee_count_actual)
    duration_max = Enum.max_by(sessions, & &1.duration_sec_actual)

    rate_best =
      sessions
      |> Enum.filter(&(&1.duration_sec_actual > 0))
      |> case do
        [] -> nil
        rated -> Enum.max_by(rated, &(&1.burpee_count_actual / &1.duration_sec_actual))
      end

    %{
      burpees_max: burpees_max,
      duration_max: duration_max,
      rate_best: rate_best
    }
  end

  defp chart_data(sessions, active_goals, user) do
    datasets =
      [:six_count, :navy_seal]
      |> Enum.flat_map(fn type ->
        [
          build_series_dataset(type, sessions),
          build_goal_dataset(type, active_goals),
          build_trend_dataset(type, user, sessions)
        ]
      end)
      |> Enum.reject(&is_nil/1)

    %{datasets: datasets}
  end

  defp build_series_dataset(type, sessions) do
    points =
      sessions
      |> Enum.filter(&(&1.burpee_type == type))
      |> Enum.sort_by(& &1.inserted_at, DateTime)
      |> Enum.map(fn session ->
        %{x: DateTime.to_date(session.inserted_at), y: session.burpee_count_actual}
      end)

    style = Map.fetch!(@series_styles, type)

    %{
      label: Fmt.burpee_type(type),
      data: points,
      borderColor: style.color,
      backgroundColor: style.background,
      tension: 0.2,
      pointRadius: 4
    }
  end

  defp build_goal_dataset(type, active_goals) do
    case Enum.find(active_goals, &(&1.burpee_type == type)) do
      nil ->
        nil

      goal ->
        style = Map.fetch!(@series_styles, type)

        %{
          label: "#{Fmt.burpee_type(type)} goal",
          data: [
            %{x: goal.date_baseline, y: goal.burpee_count_baseline},
            %{x: goal.date_target, y: goal.burpee_count_target}
          ],
          borderColor: style.color,
          borderDash: [6, 4],
          pointRadius: 0,
          borderWidth: 1
        }
    end
  end

  defp build_trend_dataset(type, user, sessions) do
    typed = Enum.filter(sessions, &(&1.burpee_type == type))

    if length(typed) >= 2 do
      recent = Workouts.list_recent_sessions(user, type, 4)
      projection = Progression.project_trend(recent)

      case projection do
        [] ->
          nil

        points ->
          style = Map.fetch!(@series_styles, type)

          %{
            label: "#{Fmt.burpee_type(type)} trend",
            data: Enum.map(points, fn {date, count} -> %{x: date, y: count} end),
            borderColor: style.color,
            borderDash: [2, 2],
            pointRadius: 0,
            borderWidth: 1,
            fill: false
          }
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="space-y-8">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">History</h1>
            <p class="text-sm text-base-content/60">
              Your sessions over time with goal + trend overlays.
            </p>
          </div>
          <.link
            navigate={~p"/log"}
            class="rounded-md border border-base-300 px-4 py-2 text-sm hover:bg-base-200 transition"
          >
            Log a session
          </.link>
        </div>

        <%= if @sessions == [] do %>
          <div class="rounded-lg border border-dashed border-base-300 p-12 text-center space-y-1">
            <p class="text-base-content/70">No sessions recorded yet.</p>
            <p class="text-sm text-base-content/50">
              Run a plan or log a free-form session to see it here.
            </p>
          </div>
        <% else %>
          <section class="rounded-lg border border-base-300 bg-base-100 p-5">
            <div class="h-72">
              <canvas
                id="history-chart"
                phx-hook="ChartHook"
                phx-update="ignore"
                data-chart={Jason.encode!(@chart)}
              >
              </canvas>
            </div>
          </section>

          <section class="grid gap-4 sm:grid-cols-2">
            <.pr_card title="6-count" pr={@prs[:six_count]} />
            <.pr_card title="Navy SEAL" pr={@prs[:navy_seal]} />
          </section>

          <section class="rounded-lg border border-base-300 bg-base-100 overflow-hidden">
            <table class="w-full text-sm">
              <thead class="bg-base-200/50 text-xs uppercase tracking-wide text-base-content/60">
                <tr>
                  <th class="text-left px-4 py-2">Date</th>
                  <th class="text-left px-4 py-2">Type</th>
                  <th class="text-right px-4 py-2">Burpees</th>
                  <th class="text-right px-4 py-2">Duration</th>
                  <th class="text-left px-4 py-2">Notes</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-200">
                <%= for session <- @sessions do %>
                  <tr class="hover:bg-base-200/30">
                    <td class="px-4 py-2">
                      {Calendar.strftime(session.inserted_at, "%Y-%m-%d")}
                    </td>
                    <td class="px-4 py-2">
                      <span class="inline-flex items-center rounded-full bg-base-200 px-2 py-0.5 text-xs">
                        {Fmt.burpee_type(session.burpee_type)}
                      </span>
                    </td>
                    <td class="px-4 py-2 text-right font-medium">
                      {session.burpee_count_actual}
                    </td>
                    <td class="px-4 py-2 text-right">
                      {Fmt.duration_sec(session.duration_sec_actual)}
                    </td>
                    <td class="px-4 py-2 text-base-content/60 truncate max-w-xs">
                      {note_preview(session)}
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :pr, :any, required: true

  defp pr_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-100 p-5 space-y-3">
      <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
        {@title} PRs
      </h3>

      <%= if @pr do %>
        <dl class="space-y-2 text-sm">
          <div class="flex justify-between gap-4">
            <dt class="text-base-content/60">Most burpees</dt>
            <dd class="font-semibold">
              {@pr.burpees_max.burpee_count_actual}
              <span class="text-xs text-base-content/50 ml-1">
                ({Calendar.strftime(@pr.burpees_max.inserted_at, "%Y-%m-%d")})
              </span>
            </dd>
          </div>
          <div class="flex justify-between gap-4">
            <dt class="text-base-content/60">Longest session</dt>
            <dd class="font-semibold">
              {Fmt.duration_sec(@pr.duration_max.duration_sec_actual)}
            </dd>
          </div>
          <%= if @pr.rate_best do %>
            <div class="flex justify-between gap-4">
              <dt class="text-base-content/60">Best rate</dt>
              <dd class="font-semibold">
                {:erlang.float_to_binary(
                  @pr.rate_best.burpee_count_actual / @pr.rate_best.duration_sec_actual * 60,
                  decimals: 1
                )} burpees / min
              </dd>
            </div>
          <% end %>
        </dl>
      <% else %>
        <p class="text-sm text-base-content/50">No sessions of this type yet.</p>
      <% end %>
    </div>
    """
  end

  defp note_preview(session) do
    notes = [session.note_pre, session.note_post] |> Enum.reject(&(&1 in [nil, ""]))

    case notes do
      [] -> "—"
      [single] -> truncate(single, 60)
      [pre, post] -> truncate(pre <> " / " <> post, 60)
    end
  end

  defp truncate(string, max) when byte_size(string) > max do
    String.slice(string, 0, max - 1) <> "…"
  end

  defp truncate(string, _), do: string
end
