defmodule BurpeeTrainerWeb.VideoLive.Index do
  @moduledoc """
  Grid of all workout videos, filterable by burpee type.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Levels, Videos}
  alias BurpeeTrainerWeb.Fmt

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, filter: :all, videos: Videos.list_videos())}
  end

  @impl true
  def handle_event("filter", %{"type" => type}, socket) do
    {filter, videos} =
      case type do
        "six_count" -> {:six_count, Videos.list_videos(:six_count)}
        "navy_seal" -> {:navy_seal, Videos.list_videos(:navy_seal)}
        _ -> {:all, Videos.list_videos()}
      end

    {:noreply, assign(socket, filter: filter, videos: videos)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_level={@current_level} current_page={:videos}>
      <div class="space-y-6">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Videos</h1>
          <p class="text-sm text-base-content/60">
            Follow along with a Busy Dad Training video, then log your session.
          </p>
        </div>

        <div class="flex gap-2">
          <button
            phx-click="filter"
            phx-value-type="all"
            class={tab_class(@filter == :all)}
          >
            All
          </button>
          <button
            phx-click="filter"
            phx-value-type="six_count"
            class={tab_class(@filter == :six_count)}
          >
            6-Count
          </button>
          <button
            phx-click="filter"
            phx-value-type="navy_seal"
            class={tab_class(@filter == :navy_seal)}
          >
            Navy SEAL
          </button>
        </div>

        <%= if @videos == [] do %>
          <div class="rounded-lg border border-base-300 bg-base-100 p-10 text-center">
            <p class="text-base-content/50 text-sm">No videos yet.</p>
          </div>
        <% else %>
          <div class="grid gap-4 sm:grid-cols-2">
            <%= for video <- @videos do %>
              <.link
                navigate={~p"/videos/#{video.id}"}
                class="group rounded-lg border border-base-300 bg-base-100 p-5 flex flex-col gap-2 hover:border-primary/40 transition-colors"
              >
                <div class="flex items-start justify-between gap-2">
                  <p class="font-medium text-base-content leading-snug">{video.name}</p>
                  <div class="shrink-0 flex gap-1.5">
                    <span class={[
                      "rounded-full px-2 py-0.5 text-xs font-medium",
                      burpee_badge_class(video.burpee_type)
                    ]}>
                      {burpee_label(video.burpee_type)}
                    </span>
                    <%= if video.burpee_count do %>
                      <span class={"rounded-full px-2 py-0.5 text-xs font-medium #{Fmt.level_color(Levels.level_for_count(video.burpee_type, video.burpee_count))}"}>
                        {Fmt.level(Levels.level_for_count(video.burpee_type, video.burpee_count))}
                      </span>
                    <% end %>
                  </div>
                </div>
                <p class="text-sm text-base-content/50">
                  {format_duration(video.duration_sec)}
                </p>
              </.link>
            <% end %>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp tab_class(true),
    do:
      "rounded-md px-4 py-1.5 text-sm font-medium bg-primary text-primary-content transition-colors"

  defp tab_class(false),
    do:
      "rounded-md px-4 py-1.5 text-sm border border-base-300 text-base-content/60 hover:text-base-content hover:border-base-content/20 transition-colors"

  defp burpee_badge_class(:six_count), do: "bg-primary/10 text-primary"
  defp burpee_badge_class(:navy_seal), do: "bg-[#F59E0B]/10 text-[#F59E0B]"

  defp burpee_label(:six_count), do: "6-Count"
  defp burpee_label(:navy_seal), do: "Navy SEAL"

  defp format_duration(sec) do
    min = div(sec, 60)
    rem = rem(sec, 60)
    if rem == 0, do: "#{min} min", else: "#{min}m #{rem}s"
  end
end
