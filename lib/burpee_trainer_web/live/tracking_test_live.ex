defmodule BurpeeTrainerWeb.TrackingTestLive do
  use BurpeeTrainerWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:tracking_test}>
      <div class="session-surface mx-auto max-w-2xl space-y-5 pb-20 text-[var(--session-ink)]">
        <div class="space-y-1">
          <p class="text-xs font-semibold uppercase tracking-widest text-[var(--session-muted)]">
            Tracking Test
          </p>
          <h1 class="text-3xl font-bold tracking-tight">Camera + pose overlay</h1>
          <p class="text-sm text-[var(--session-muted)]">
            Local-only diagnostic view for BlazePose full keypoints, pose features, and rep counting.
          </p>
        </div>

        <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
          <button
            id="pose-debug-template-start"
            type="button"
            phx-hook="PoseCalibrationButton"
            class="relative z-20 w-full touch-manipulation select-none border border-[var(--session-ink)] bg-[var(--session-ink)] px-4 py-4 text-base font-semibold text-[var(--session-bg)] transition hover:opacity-90 active:scale-[0.99]"
          >
            Start 3s countdown
          </button>
          <button
            id="pose-debug-trace-start"
            type="button"
            phx-hook="PoseTraceButton"
            class="relative z-20 w-full touch-manipulation select-none border border-[var(--session-border)] bg-[var(--session-surface)] px-4 py-4 text-base font-semibold text-[var(--session-ink)] transition hover:border-[var(--session-ink)] active:scale-[0.99]"
          >
            Record 10s trace
          </button>
        </div>

        <section class="border border-[var(--session-border)] bg-[var(--session-surface)] p-3 space-y-3">
          <div
            id="pose-debug"
            phx-hook="PoseDebug"
            phx-update="ignore"
            class="space-y-3"
          >
            <div class="relative overflow-hidden bg-black aspect-[3/4]">
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

            <div class="border border-[var(--session-border)] bg-[var(--session-track)]/30 p-3 space-y-3">
              <div>
                <p class="text-[10px] uppercase tracking-widest text-[var(--session-muted)]">
                  DTW calibration
                </p>
                <p class="mt-1 text-xs text-[var(--session-muted)]">
                  Tap once, put the phone down, wait for the countdown, and do one clean full rep. The template saves automatically after 5 seconds.
                </p>
              </div>
              <div class="grid grid-cols-2 gap-2 text-sm">
                <.debug_stat label="DTW" value_id="pose-debug-dtw-status" value="No template" />
                <.debug_stat label="DTW reps" value_id="pose-debug-dtw-reps" value="0" />
              </div>
              <p id="pose-debug-dtw-detail" class="text-xs text-[var(--session-muted)] break-words">
                []
              </p>
            </div>

            <div class="border border-[var(--session-border)] bg-[var(--session-track)]/30 p-3 space-y-3">
              <div>
                <p class="text-[10px] uppercase tracking-widest text-[var(--session-muted)]">
                  Decoder diagnostics
                </p>
                <p class="mt-1 text-xs text-[var(--session-muted)]">
                  Debug-only HMM/HSMM phase loop output. This does not drive workout rep counting yet.
                </p>
              </div>
              <div class="grid grid-cols-2 gap-2 text-sm">
                <.debug_stat label="Decoded phase" value_id="pose-debug-decoder-phase" value="—" />
                <.debug_stat label="Candidates" value_id="pose-debug-decoder-candidates" value="0" />
                <.debug_stat
                  label="Illegal transitions"
                  value_id="pose-debug-decoder-illegal-transitions"
                  value="0"
                />
                <.debug_stat
                  label="Unknown span"
                  value_id="pose-debug-decoder-max-unknown"
                  value="0ms"
                />
              </div>
              <p
                id="pose-debug-decoder-segments"
                class="text-xs text-[var(--session-muted)] break-words"
              >
                []
              </p>
            </div>

            <div class="border border-[var(--session-border)] bg-[var(--session-track)]/30 p-3 space-y-3">
              <div>
                <p class="text-[10px] uppercase tracking-widest text-[var(--session-muted)]">
                  Trace recorder
                </p>
                <p class="mt-1 text-xs text-[var(--session-muted)]">
                  Records local pose features for 10 seconds after a countdown. Copy the JSON below after it says Trace ready.
                </p>
              </div>
              <div class="grid grid-cols-2 gap-2 text-sm">
                <.debug_stat label="Trace" value_id="pose-debug-trace-status" value="Trace idle" />
                <.debug_stat label="Samples" value_id="pose-debug-trace-count" value="0" />
              </div>
              <textarea
                id="pose-debug-trace-output"
                readonly
                class="min-h-32 w-full border border-[var(--session-border)] bg-[var(--session-surface)] p-2 text-[10px] text-[var(--session-muted)]"
              >[]</textarea>
            </div>

            <div class="border border-[var(--session-border)] bg-[var(--session-track)]/30 p-3">
              <p class="text-[10px] uppercase tracking-widest text-[var(--session-muted)]">Cadence</p>
              <p id="pose-debug-cadence" class="mt-1 text-xs text-[var(--session-muted)] break-words">
                []
              </p>
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
    <div class="border border-[var(--session-border)] bg-[var(--session-track)]/30 p-3">
      <p class="text-[10px] uppercase tracking-widest text-[var(--session-muted)]">{@label}</p>
      <p id={@value_id} class="mt-1 text-lg font-bold tabular-nums">{@value}</p>
    </div>
    """
  end
end
