defmodule BurpeeTrainerWeb.HomeScreen do
  @moduledoc "Home.State-driven card presentation and result field projection."
  use BurpeeTrainerWeb, :html
  import Phoenix.LiveView
  alias BurpeeTrainerWeb.{Fmt, HomeWorkoutComponents, HomeCoachComponents}

  def assign_results(socket, results) do
    case results do
      %{} = results ->
        rows =
          if socket.assigns.slot.home_state == :done_today, do: results.today, else: results.week

        reps =
          Map.new([:six_count, :navy_seal], fn type ->
            {type,
             rows
             |> Enum.filter(&(&1.burpee_type == type))
             |> Enum.sum_by(&(&1.burpee_count_actual || 0))}
          end)

        latest_today = List.first(results.today)

        socket
        |> assign(
          result_actual_seconds: Enum.sum_by(results.today, &(&1.duration_sec_actual || 0)),
          result_today_reps: Enum.sum_by(results.today, &(&1.burpee_count_actual || 0)),
          result_today_count: length(results.today),
          result_today_session: latest_today,
          result_mood: latest_today && mood_label(latest_today.mood),
          result_reps: reps
        )
        |> stream(:result_sessions, results.today, reset: true)

      nil ->
        socket
        |> assign(
          result_actual_seconds: nil,
          result_today_reps: 0,
          result_today_count: 0,
          result_today_session: nil,
          result_mood: nil,
          result_reps: %{six_count: 0, navy_seal: 0}
        )
        |> stream(:result_sessions, [], reset: true)
    end
  end

  defp mood_label(-1), do: "Rough"
  defp mood_label(0), do: "OK"
  defp mood_label(1), do: "Good"
  defp mood_label(_), do: nil

  defp state_tag({state, _}), do: state
  defp state_tag(state), do: state

  def screen(assigns) do
    ~H"""
    <main
      id="home-page"
      data-home-state={state_tag(@home_state)}
      class="mx-auto w-full max-w-3xl px-5 py-10 sm:px-8 sm:py-16"
    >
      <div class="adaptive-home">
        <div id="home-progress-history" class="relative min-h-11">
          <%= if @slot do %>
            <HomeWorkoutComponents.week_progress slot={@slot} />
          <% else %>
            <p id="home-progress-unavailable">Weekly progress unavailable</p>
          <% end %>
          <.link
            id="home-history-toggle"
            data-primary-action={@home_primary_action == :insights && "insights"}
            patch={~p"/history"}
            class="absolute inset-0 min-h-11 rounded-sm focus-visible:outline-2 focus-visible:outline-offset-4"
            aria-label="Open History"
            phx-mounted={@home_focus_return? && Phoenix.LiveView.JS.focus(to: "#home-history-toggle")}
          >
            <span class="sr-only">View training history</span>
          </.link>
        </div>
        <div id="home-state-content">
          <%= case @home_state do %>
            <% {:resume, _session} -> %>
              <section
                id="home-ready-recommendation"
                class="home-result home-resume"
                phx-hook="HomePendingSession"
                data-session-id={@started_session.id}
                data-content-hash={@started_session.content_hash}
              >
                <p id="home-session-state" class="home-eyebrow">In progress</p>
                <div class="home-hero">
                  <h1 class="home-state-heading">
                    {@started_session.display_name_snapshot ||
                      Fmt.burpee_type(@started_session.burpee_type)}
                  </h1>
                  <p class="home-resume-style">
                    {Fmt.burpee_type(@started_session.burpee_type)}
                    <span :if={@started_session.style_name}>
                      · {@started_session.style_name}
                    </span>
                  </p>
                  <p class="home-resume-meta">
                    <span :if={@started_session.burpee_count_planned}>
                      {@started_session.burpee_count_planned} reps
                    </span>
                    <span :if={@started_session.duration_sec_planned}>
                      {Fmt.duration_sec(@started_session.duration_sec_planned)} planned
                    </span>
                  </p>
                </div>
                <button
                  id="resume-recommended-workout"
                  data-primary-action="resume"
                  type="button"
                  phx-click="resume_recommendation"
                  phx-value-session-id={@started_session.id}
                  class="home-resume-action min-h-11 focus-visible:outline-2 focus-visible:outline-offset-4"
                >
                  <span id="home-resume-action-label">Resume workout</span>
                  <.icon name="hero-arrow-right" class="size-4" />
                </button>
              </section>
            <% nil -> %>
              <section id="home-unavailable" class="home-result">
                <p role="status">{@home_error}</p>
                <a
                  id="home-reload"
                  href={~p"/"}
                  class="mt-4 inline-flex min-h-11 items-center underline focus-visible:outline-2"
                >
                  Reload Home
                </a>
              </section>
            <% {state, _results} when state in [:done_today, :week_complete] -> %>
              <%= if @result_today_session do %>
                <section id="home-done-today" class="home-result">
                  <p class="home-state-label">Today</p>
                  <h1 class="home-state-heading">
                    {@result_today_session.display_name_snapshot ||
                      Fmt.burpee_type(@result_today_session.burpee_type)}
                  </h1>
                  <p
                    id={
                      if(@result_today_count == 1,
                        do: "home-result-actual-seconds",
                        else: "home-today-session-meta"
                      )
                    }
                    data-duration-sec={@result_today_session.duration_sec_actual}
                    class="home-result-meta"
                  >
                    {Fmt.duration_sec(@result_today_session.duration_sec_actual)} · {@result_today_session.burpee_count_actual ||
                      0} reps
                  </p>
                  <p :if={@result_mood} id="home-today-mood" class="home-result-mood">
                    {@result_mood}
                  </p>
                  <p
                    :if={@result_today_count > 1}
                    id="home-result-actual-seconds"
                    data-duration-sec={@result_actual_seconds}
                    class="home-result-meta"
                  >
                    Today total · {Fmt.duration_sec(@result_actual_seconds)} · {@result_today_reps} reps
                  </p>
                  <HomeCoachComponents.entry
                    id="home-result-coach"
                    return_focus?={@home_coach_focus_return?}
                  />
                </section>
              <% else %>
                <section
                  id="home-week-complete"
                  class="home-result"
                >
                  <p class="home-state-label">
                    This week
                  </p>
                  <h1 class="home-state-heading">
                    Training target complete
                  </h1>
                  <p
                    id="home-result-actual-seconds"
                    data-duration-sec={@slot.completed_sec}
                    class="home-result-meta"
                  >
                    {Fmt.duration_sec(@slot.completed_sec)} · {@result_reps.six_count +
                      @result_reps.navy_seal} reps
                  </p>
                  <HomeCoachComponents.entry
                    id="home-result-coach"
                    return_focus?={@home_coach_focus_return?}
                  />
                </section>
              <% end %>
            <% :first_workout -> %>
              <HomeWorkoutComponents.bootstrap state={assigns} />
            <% {:start, _selection} -> %>
              <HomeWorkoutComponents.workspace state={assigns} />
            <% :choose -> %>
              <HomeWorkoutComponents.choose state={assigns} />
            <% :unavailable -> %>
              <section
                id="home-ready-recommendation"
                class="home-result"
              >
                <h1 class="home-state-heading">
                  Your workout is being prepared
                </h1>
                <p :if={@local_error} id="home-initialization-error" role="status">
                  {@local_error}
                </p>
                <a
                  :if={@local_error}
                  id="home-fallback-reload"
                  href={~p"/"}
                  class="mt-4 inline-flex min-h-11 items-center underline focus-visible:outline-2"
                >
                  Reload Home
                </a>
                <button
                  :if={is_nil(@local_error)}
                  id="retry-recommendation-button"
                  phx-click="retry_recommendation"
                  class="home-state-action min-h-11 focus-visible:outline-2 focus-visible:outline-offset-4"
                >
                  Retry
                </button>
              </section>
          <% end %>
        </div>
      </div>
    </main>
    """
  end
end
