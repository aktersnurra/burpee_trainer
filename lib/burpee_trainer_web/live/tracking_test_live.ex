defmodule BurpeeTrainerWeb.TrackingTestLive do
  use BurpeeTrainerWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:stats}>
      <div class="mx-auto max-w-2xl space-y-5 pb-20">
        <div class="space-y-1">
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content/40">
            Tracking Test
          </p>
          <h1 class="text-3xl font-bold tracking-tight">Camera + pose overlay</h1>
          <p class="text-sm text-base-content/50">
            Local-only diagnostic view for MoveNet keypoints, up/down signal, and rep counting.
          </p>
        </div>

        <section class="rounded-[10px] bg-base-300 p-3 space-y-3">
          <div
            id="pose-debug"
            phx-hook="PoseDebug"
            phx-update="ignore"
            class="space-y-3"
          >
            <div class="relative overflow-hidden rounded-[10px] bg-black aspect-[3/4]">
              <video
                id="pose-debug-video"
                class="absolute inset-0 h-full w-full object-cover scale-x-[-1]"
                muted
                playsinline
              >
              </video>
              <canvas id="pose-debug-canvas" class="absolute inset-0 h-full w-full"></canvas>
            </div>

            <div class="grid grid-cols-2 gap-2 text-sm">
              <.debug_stat label="Status" value_id="pose-debug-status" value="Idle" />
              <.debug_stat label="FPS" value_id="pose-debug-fps" value="—" />
              <.debug_stat label="Confidence" value_id="pose-debug-confidence" value="—" />
              <.debug_stat label="Signal" value_id="pose-debug-signal" value="—" />
              <.debug_stat label="Phase" value_id="pose-debug-phase" value="—" />
              <.debug_stat label="Reps" value_id="pose-debug-reps" value="0" />
            </div>

            <div class="rounded-[10px] bg-base-100/50 p-3">
              <p class="text-[10px] uppercase tracking-widest text-base-content/40">Cadence</p>
              <p id="pose-debug-cadence" class="mt-1 text-xs text-base-content/60 break-words">[]</p>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr(:label, :string, required: true)
  attr(:value_id, :string, required: true)
  attr(:value, :string, required: true)

  defp debug_stat(assigns) do
    ~H"""
    <div class="rounded-[10px] bg-base-100/50 p-3">
      <p class="text-[10px] uppercase tracking-widest text-base-content/40">{@label}</p>
      <p id={@value_id} class="mt-1 text-lg font-bold tabular-nums">{@value}</p>
    </div>
    """
  end
end
