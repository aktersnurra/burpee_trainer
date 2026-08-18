defmodule BurpeeTrainerWeb.VideoLive.Index do
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Videos, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession
  alias BurpeeTrainerWeb.Fmt

  @impl true
  def mount(_params, _session, socket) do
    videos = Videos.list_available_follow_along_videos()
    client_session_ids = Map.new(videos, &{&1.id, Ecto.UUID.generate()})

    {:ok,
     socket
     |> assign(:client_session_ids, client_session_ids)
     |> stream(:videos, videos, dom_id: fn video -> "video-card-#{video.id}" end)}
  end

  @impl true
  def handle_event(
        "start_video",
        %{"video_id" => video_id, "client_session_id" => client_session_id},
        socket
      ) do
    with {:ok, video_id} <- parse_positive_id(video_id),
         true <- is_binary(client_session_id),
         {:ok, session} <-
           Workouts.start_video(socket.assigns.current_user, video_id, client_session_id),
         {:ok, route} <- session_route(session) do
      {:noreply, push_navigate(socket, to: route)}
    else
      _error -> {:noreply, put_flash(socket, :error, "Video is unavailable.")}
    end
  end

  def handle_event("start_video", _params, socket) do
    {:noreply, put_flash(socket, :error, "Video is unavailable.")}
  end

  defp parse_positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> {:error, :invalid_id}
    end
  end

  defp parse_positive_id(_forged), do: {:error, :invalid_id}

  defp session_route(%WorkoutSession{source_kind: :plan, id: session_id}),
    do: {:ok, ~p"/session/#{session_id}"}

  defp session_route(%WorkoutSession{
         source_kind: :video,
         workout_video_id: video_id,
         id: session_id
       })
       when is_integer(video_id),
       do: {:ok, ~p"/videos/#{video_id}/session/#{session_id}"}

  defp session_route(%WorkoutSession{}), do: {:error, :unsupported_session_source}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_level={@current_level}
      current_scope={assigns[:current_scope]}
      current_page={:videos}
    >
      <div
        id="videos-page"
        class="session-surface mx-auto max-w-lg space-y-8 pb-24 text-[var(--session-ink)]"
      >
        <header class="space-y-2 px-1">
          <p class="text-sm font-medium text-[var(--session-muted)]">Video library</p>
          <h1 class="text-3xl font-semibold leading-none tracking-[-0.05em] text-[var(--session-ink)]">
            Train alongside a video
          </h1>
          <p class="max-w-md text-sm leading-6 text-[var(--session-muted)]">
            Browse follow-along sessions and start an immutable workout session.
          </p>
        </header>

        <div id="videos-list" phx-update="stream" class="space-y-3">
          <.qs_surface
            id="videos-empty-state"
            class="hidden only:block bg-[var(--session-surface)]/45 px-6 py-14 text-center"
          >
            <p class="text-base font-semibold text-[var(--session-ink)]">No videos available</p>
            <p class="mt-2 text-sm text-[var(--session-muted)]">
              Follow-along sessions will appear here when they are ready.
            </p>
          </.qs_surface>

          <.qs_surface
            :for={{dom_id, video} <- @streams.videos}
            id={dom_id}
            class="bg-[var(--session-surface)]/55 p-5 transition hover:-translate-y-0.5 hover:bg-[var(--session-surface-alt)]/70"
          >
            <div class="flex items-center justify-between gap-5">
              <.link navigate={~p"/videos/#{video.id}"} class="min-w-0 flex-1 space-y-3">
                <div class="flex flex-wrap items-center gap-1.5">
                  <.qs_property_tag tone="tag">Video</.qs_property_tag>
                  <.qs_property_tag tone="info">
                    {Fmt.burpee_type(video.burpee_type)}
                  </.qs_property_tag>
                </div>
                <div>
                  <h2 class="truncate text-xl font-semibold leading-tight tracking-[-0.03em] text-[var(--session-ink)]">
                    {video.name}
                  </h2>
                  <p class="mt-1 text-sm font-medium tabular-nums text-[var(--session-muted)]">
                    {Fmt.duration_sec(video.duration_sec)}
                    <%= if video.burpee_count do %>
                      · {video.burpee_count} reps
                    <% end %>
                  </p>
                </div>
              </.link>

              <button
                id={"video-start-#{video.id}"}
                type="button"
                phx-click="start_video"
                phx-value-video_id={video.id}
                phx-value-client_session_id={@client_session_ids[video.id]}
                class="flex size-11 shrink-0 items-center justify-center rounded-full border border-[var(--session-border)] bg-[var(--session-bg)]/55 text-[var(--session-ink)] transition hover:border-[var(--session-ink)]"
                aria-label={"Start #{video.name}"}
              >
                <.icon name="hero-play-solid" class="size-4" />
              </button>
            </div>
          </.qs_surface>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
