defmodule BurpeeTrainerWeb.HomeScreen do
  @moduledoc "Home.State-driven card presentation and result field projection."
  use BurpeeTrainerWeb, :html
  import Phoenix.LiveView
  alias BurpeeTrainerWeb.{Fmt, HomeWorkoutComponents}

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

  # What the started workout is, on one line: type, style, reps, time.
  defp resume_meta(session) do
    [
      Fmt.burpee_type(session.burpee_type),
      session.style_name,
      session.burpee_count_planned && "#{session.burpee_count_planned} reps",
      session.duration_sec_planned && Fmt.duration_sec(session.duration_sec_planned)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp state_tag({state, _}), do: state
  defp state_tag(state), do: state

  attr(:expanded?, :boolean, required: true)
  slot(:inner_block, required: true)

  # The result's title opens and closes the coach, as the workout's title opens the workout.
  defp done_toggle(assigns) do
    ~H"""
    <button
      id="home-done-summary"
      type="button"
      phx-click="coach_toggle"
      class={["home-summary", @expanded? && "home-summary-expanded"]}
      aria-expanded={to_string(@expanded?)}
      aria-controls="home-coach-panel"
    >
      <span class="home-workout-name">{render_slot(@inner_block)}</span>
    </button>
    """
  end

  def screen(assigns) do
    ~H"""
    <main
      id="home-page"
      data-home-state={state_tag(@home_state)}
      class="mx-auto w-full max-w-3xl px-5 py-10 sm:px-8 sm:py-16"
    >
      <p :if={@home_planning_error} id="home-planning-error" role="status" class="home-local-message">
        {@home_planning_error}
      </p>
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
            patch={~p"/progress"}
            class="absolute inset-0 min-h-11 rounded-sm focus-visible:outline-2 focus-visible:outline-offset-4"
            aria-label="Open Progress"
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
                <%!-- Laid out like the workout and the result: title, one line of what it is,
                     its state, then the one action. --%>
                <h1 class="home-state-heading">
                  {@started_session.display_name_snapshot ||
                    Fmt.burpee_type(@started_session.burpee_type)}
                </h1>
                <p class="home-result-meta home-resume-meta">{resume_meta(@started_session)}</p>
                <p id="home-session-state" class="home-result-status">In progress</p>
                <button
                  id="resume-recommended-workout"
                  data-primary-action="resume"
                  type="button"
                  phx-click="resume_recommendation"
                  phx-value-session-id={@started_session.id}
                  class="home-primary-action home-play-action"
                >
                  <.icon name="hero-play-solid" class="size-6" />
                  <%!-- Named for screen readers; the hook says "Review & save" for a draft. --%>
                  <span id="home-resume-action-label" class="sr-only">Resume</span>
                </button>
              </section>
            <% nil -> %>
              <section id="home-unavailable" class="home-result">
                <p role="status">{@home_error}</p>
                <a
                  id="home-reload"
                  href={~p"/"}
                  class="home-text-action home-icon-action mt-4"
                  aria-label="Reload Home"
                  title="Reload Home"
                >
                  <.icon name="hero-arrow-path" class="size-5" />
                </a>
              </section>
            <% {state, _results} when state in [:done_today, :week_complete] -> %>
              <%= if @result_today_session do %>
                <section
                  id="home-done-today"
                  class="home-result"
                  data-expanded={to_string(@coach_expanded?)}
                >
                  <h1 class="home-state-heading">
                    <.done_toggle expanded?={@coach_expanded?}>
                      {@result_today_session.display_name_snapshot ||
                        Fmt.burpee_type(@result_today_session.burpee_type)}
                    </.done_toggle>
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
                </section>
              <% else %>
                <section
                  id="home-week-complete"
                  class="home-result"
                  data-expanded={to_string(@coach_expanded?)}
                >
                  <h1 class="home-state-heading">
                    <.done_toggle expanded?={@coach_expanded?}>Training target complete</.done_toggle>
                  </h1>
                  <p
                    id="home-result-actual-seconds"
                    data-duration-sec={@slot.completed_sec}
                    class="home-result-meta"
                  >
                    {Fmt.duration_sec(@slot.completed_sec)} · {@result_reps.six_count +
                      @result_reps.navy_seal} reps
                  </p>
                </section>
              <% end %>
              <%!-- The coach's line follows the result, the way it follows the workout before. --%>
              <p :if={@home_insight} id="home-insight-headline" class="home-result-insight">
                {@home_insight.headline}
              </p>
              <p
                :if={is_nil(@home_insight) and @result_today_session}
                id="home-done-status"
                class="home-result-insight home-result-status"
              >
                Done for today.
              </p>
              <%!-- Done is when there is something to talk about: the result opens, like the
                   workout day, onto the coach's report on the week and the conversation. --%>
              <div
                id="home-done-expansion"
                class="home-expansion"
                data-open={to_string(@coach_expanded?)}
              >
                <div
                  class="home-expansion-content"
                  inert={!@coach_expanded?}
                  aria-hidden={to_string(!@coach_expanded?)}
                >
                  <BurpeeTrainerWeb.HomeCoachComponents.panel state={assigns} />
                </div>
              </div>
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
                  class="home-text-action home-icon-action mt-4"
                  aria-label="Reload Home"
                  title="Reload Home"
                >
                  <.icon name="hero-arrow-path" class="size-5" />
                </a>
                <button
                  :if={is_nil(@local_error)}
                  id="retry-recommendation-button"
                  phx-click="retry_recommendation"
                  class="home-state-action min-h-11 focus-visible:outline-2 focus-visible:outline-offset-4 home-icon-action"
                  aria-label="Retry"
                  title="Retry"
                >
                  <.icon name="hero-arrow-path" class="size-5" />
                </button>
              </section>
          <% end %>
        </div>
      </div>
    </main>
    """
  end
end
