defmodule BurpeeTrainerWeb.HomeScreen do
  @moduledoc "Home.State-driven card presentation and result field projection."
  use BurpeeTrainerWeb, :html
  import Phoenix.LiveView
  alias BurpeeTrainerWeb.{Fmt, HomeCoachComponents, HomeStudioComponents, HomeWorkoutComponents}

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
          result_reps: %{six_count: 0, navy_seal: 0}
        )
        |> stream(:result_sessions, [], reset: true)
    end
  end

  # The started workout's totals, as Home shows a workout's: minutes, then reps.
  defp resume_meta(session) do
    [
      session.duration_sec_planned &&
        HomeWorkoutComponents.duration_label(session.duration_sec_planned),
      session.burpee_count_planned && "#{session.burpee_count_planned} reps"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp state_tag({state, _}), do: state
  defp state_tag(state), do: state

  slot(:inner_block, required: true)

  defp done_title(assigns) do
    ~H"""
    <span id="home-done-summary" class="home-summary">
      <span class="home-workout-name">{render_slot(@inner_block)}</span>
    </span>
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
      <HomeStudioComponents.studio :if={HomeStudioComponents.studio?(assigns)} state={assigns} />
      <%!-- The whole screen takes the swipe right to swap the workout; the drawer's button stays
           for anyone who cannot swipe. --%>
      <div
        :if={not HomeStudioComponents.studio?(assigns)}
        id="home-gestures"
        class="adaptive-home"
        phx-hook="HomeGestures"
        data-chooser-open={to_string(@chooser_open?)}
      >
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
            data-vt="forward"
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
                <div class="home-resume-actions">
                  <HomeWorkoutComponents.start_choice choice="camera" />
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
                  <HomeWorkoutComponents.start_choice choice="warmup" />
                </div>
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
                  data-expanded={to_string(HomeCoachComponents.shown?(assigns))}
                >
                  <h1 class="home-state-heading">
                    <.done_title>
                      {@result_today_session.display_name_snapshot ||
                        Fmt.burpee_type(@result_today_session.burpee_type)}
                    </.done_title>
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
                  data-expanded={to_string(HomeCoachComponents.shown?(assigns))}
                >
                  <h1 class="home-state-heading">
                    <.done_title>Training target complete</.done_title>
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
              <%!-- Done is when there is something to talk about: the coach's report on the week
                   and the conversation sit open under the result. --%>
              <HomeCoachComponents.panel :if={HomeCoachComponents.shown?(assigns)} state={assigns} />
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
