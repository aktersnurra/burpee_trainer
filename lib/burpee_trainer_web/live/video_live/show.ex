defmodule BurpeeTrainerWeb.VideoLive.Show do
  @moduledoc """
  A video session: the video plays from its immutable snapshot, then it ends on the same
  finish screen as a plan session (`SessionComponents.completion_review`). Finish early,
  Abort and the finish screen's trash ask in place before they act. With the device's camera
  on (`StartChoices`), the camera counts the reps as the video plays (`VideoHook`, the
  `PoseTracker`), and the finish screen starts at its count.
  """

  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.WorkoutSession
  alias BurpeeTrainerWeb.{Fmt, Params, SessionComponents, StartChoices}

  # The plan session's finish screen choices, so a video logs the same way.
  @mood_options SessionComponents.mood_options()
  @tag_options SessionComponents.tag_options()
  @tag_values Enum.map(@tag_options, &elem(&1, 1))
  # What asks before it acts: Finish early and Abort while watching, trash when finished.
  @armable ~w(finish abort delete)
  @events %{
    step: "step_reps",
    mood: "set_mood",
    tag: "toggle_tag",
    change: "validate",
    submit: "save",
    arm: "arm",
    disarm: "disarm",
    discard: "discard"
  }

  @impl true
  def mount(%{"video_id" => video_id, "session_id" => session_id}, session, socket) do
    scope = socket.assigns.current_scope

    with {:ok, video_id} <- Params.positive_id(video_id),
         {:ok, session_id} <- Params.positive_id(session_id),
         {:ok,
          %WorkoutSession{
            source_kind: :video,
            workout_video_id: ^video_id,
            video_snapshot: snapshot
          } = workout_session} <- Workouts.resume_session(scope, session_id) do
      {:ok,
       socket
       |> assign(:camera?, camera?(socket, session))
       |> mount_video_session(video_id, snapshot, workout_session)}
    else
      _unavailable -> unavailable_video(socket)
    end
  end

  # The device's camera choice, as Home's toggle left it.
  defp camera?(socket, session) do
    choices =
      if connected?(socket),
        do: StartChoices.from_connect_params(get_connect_params(socket)),
        else: session["start_choices"] || %{}

    Map.get(choices, "camera", false)
  end

  defp mount_video_session(socket, video_id, snapshot, session) do
    video = %{
      id: video_id,
      name: snapshot["name"],
      filename: snapshot["filename"],
      burpee_type: String.to_existing_atom(snapshot["type"]),
      duration_sec: snapshot["duration"],
      burpee_count: snapshot["count"],
      format: String.to_existing_atom(snapshot["format"])
    }

    socket
    |> assign(:video, video)
    |> assign(:workout_session, session)
    |> assign(:finished?, false)
    |> assign(:watched_sec, video.duration_sec)
    |> assign(:armed, nil)
    |> assign(:counted_reps, nil)
    |> assign(:reps, video.burpee_count || 0)
    |> assign(:mood, nil)
    |> assign(:tags, [])
    |> assign(:note, "")
    |> assign(:form, to_form(Ecto.Changeset.change(session)))
  end

  defp unavailable_video(socket) do
    {:ok,
     socket
     |> put_flash(:error, "Video session not found.")
     |> push_navigate(to: ~p"/")}
  end

  @impl true
  # The hook sends how far the video got (its end, or where Finish early stopped it) and,
  # with the camera on, how many reps it counted.
  def handle_event("video_ended", params, socket) do
    duration = socket.assigns.video.duration_sec

    watched =
      case params do
        %{"watched_sec" => sec} when is_integer(sec) and sec in 0..duration//1 -> sec
        _whole_video -> duration
      end

    socket =
      case params do
        %{"counted_reps" => reps}
        when socket.assigns.camera? and is_integer(reps) and reps >= 0 ->
          assign(socket, reps: reps, counted_reps: reps)

        _not_counted ->
          socket
      end

    {:noreply, assign(socket, finished?: true, armed: nil, watched_sec: watched)}
  end

  # The first tap asks; the question shows until a second tap, or a tap anywhere else.
  def handle_event("arm", %{"choice" => choice}, socket) when choice in @armable,
    do: {:noreply, assign(socket, :armed, choice)}

  def handle_event("arm", _params, socket), do: {:noreply, socket}

  def handle_event("disarm", _params, socket), do: {:noreply, assign(socket, :armed, nil)}

  # Abort while watching, or trash on the finish screen, asked and tapped again.
  def handle_event("discard", _params, %{assigns: %{armed: armed}} = socket)
      when armed in ["abort", "delete"] do
    with {:ok, session} <- own_video_session(socket),
         {:ok, _discarded} <-
           Workouts.discard_started_session(socket.assigns.current_scope, session.id) do
      {:noreply, socket |> put_flash(:info, "Workout discarded.") |> push_navigate(to: ~p"/")}
    else
      :refused ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:armed, nil)
         |> put_flash(:error, "Could not discard this workout. Please try again.")}
    end
  end

  def handle_event("discard", _params, socket), do: {:noreply, socket}

  def handle_event("step_reps", %{"step" => step}, socket) when step in ["-1", "1"] do
    reps = max(socket.assigns.reps + String.to_integer(step), 0)
    {:noreply, assign(socket, :reps, reps)}
  end

  def handle_event("step_reps", _params, socket), do: {:noreply, socket}

  def handle_event("set_mood", %{"mood" => mood}, socket) do
    case Enum.find(@mood_options, fn {_label, value} -> Integer.to_string(value) == mood end) do
      # Tapping the chosen mood again clears it: mood is optional.
      {_label, value} when value == socket.assigns.mood -> {:noreply, assign(socket, :mood, nil)}
      {_label, value} -> {:noreply, assign(socket, :mood, value)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("set_mood", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_tag", %{"tag" => tag}, socket) when tag in @tag_values do
    tags = socket.assigns.tags
    tags = if tag in tags, do: List.delete(tags, tag), else: [tag | tags]
    {:noreply, assign(socket, :tags, tags)}
  end

  def handle_event("toggle_tag", _params, socket), do: {:noreply, socket}

  def handle_event("validate", %{"workout_session" => params}, socket) when is_map(params) do
    case own_video_session(socket) do
      {:ok, session} ->
        note = string_param(params, "note_post", socket.assigns.note)

        # The note renders from the form, so what is typed survives a tap on a mood or tag.
        {:noreply,
         socket
         |> assign(:note, note)
         |> assign(:form, to_form(Ecto.Changeset.change(session, note_post: note)))
         |> assign(:reps, typed_reps(params, socket.assigns.reps))}

      :refused ->
        {:noreply, socket}
    end
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"workout_session" => params}, socket) when is_map(params) do
    case own_video_session(socket) do
      {:ok, session} -> save(socket, session, completion_params(params, socket.assigns))
      :refused -> {:noreply, socket}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  defp save(socket, session, params) do
    scope = socket.assigns.current_scope

    case Workouts.complete_session(scope, session.id, params, capture(socket.assigns)) do
      {:ok, session} ->
        _events = Workouts.session_milestones(scope, session)
        {:noreply, socket |> put_flash(:info, "Session logged.") |> push_navigate(to: ~p"/")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not log this session. Please try again.")}
    end
  end

  # Counted by the camera, a video is a tracked session; with no beat to keep, it has no
  # cadence to judge it by.
  defp capture(%{counted_reps: reps}) when is_integer(reps), do: :manual_correction
  defp capture(_assigns), do: :logged

  # Only the signed-in user's own started video session is completed or discarded here.
  defp own_video_session(%{
         assigns: %{
           current_scope: %{user: %{id: user_id}},
           workout_session:
             %WorkoutSession{state: :started, source_kind: :video, user_id: user_id} = session
         }
       }),
       do: {:ok, session}

  defp own_video_session(_socket), do: :refused

  # The time taken is how far the video got. The count is what was typed or stepped to;
  # anything that is not a whole number goes to the changeset as given.
  defp completion_params(params, assigns) do
    %{
      "burpee_count_actual" => Map.get(params, "burpee_count_actual", assigns.reps),
      "duration_sec_actual" => assigns.watched_sec,
      "note_post" => Map.get(params, "note_post", assigns.note),
      "mood" => assigns.mood,
      "tags" => assigns.tags |> Enum.sort() |> Enum.join(",")
    }
  end

  # Who counted, in the runner's words; once corrected, what the camera counted stays in view.
  defp count_source(nil, _reps), do: nil
  defp count_source(counted, counted), do: "Counted by camera"
  defp count_source(counted, _reps), do: "Camera counted #{counted}"

  defp typed_reps(params, reps) do
    case Integer.parse(string_param(params, "burpee_count_actual", "")) do
      {typed, ""} when typed >= 0 -> typed
      _not_a_count -> reps
    end
  end

  defp string_param(params, key, default) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _missing -> default
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :events, @events)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_level={@current_level}
      current_scope={@current_scope}
      navigation?={false}
    >
      <div
        id="video-session"
        data-session-id={@workout_session.id}
        data-client-session-id={@workout_session.client_session_id}
        data-content-hash={@workout_session.content_hash}
        data-camera={to_string(@camera?)}
        data-armed={@armed}
        phx-window-keydown={@armed && "disarm"}
        phx-key="Escape"
        class="session-surface mx-auto w-full max-w-[480px] px-1 pb-10 pt-[max(2rem,env(safe-area-inset-top))] text-[var(--session-ink)]"
      >
        <section :if={!@finished?} id="video-watch" aria-labelledby="video-heading">
          <%!-- Armed, the title gives way to Finish early's or Abort's question. --%>
          <div class="video-watch-head">
            <div id="video-title-block">
              <h1 id="video-heading" class="qs-heading-tight text-2xl font-medium">{@video.name}</h1>
              <p class="qs-tabular mt-1 text-sm text-[var(--session-muted)]">
                {Fmt.burpee_type(@video.burpee_type)} · {Fmt.duration_sec(@video.duration_sec)}
              </p>
            </div>
            <div
              id="video-finish-question"
              class="session-pause-question"
              aria-hidden={to_string(@armed != "finish")}
            >
              <p class="video-question">Finish early?</p>
              <p class="video-question-meta">What you've done is kept.</p>
            </div>
            <div
              id="video-abort-question"
              class="session-pause-question"
              aria-hidden={to_string(@armed != "abort")}
            >
              <p class="video-question">Abort workout?</p>
              <p class="video-question-meta">It won't be saved.</p>
            </div>
          </div>
          <div class="relative mt-6">
            <video
              id="workout-video"
              phx-hook="VideoHook"
              src={~p"/videos/stream/#{@video.filename}"}
              controls
              playsinline
              class="aspect-video w-full rounded-2xl bg-black"
            ></video>
            <%!-- With the camera on, its feed in the video's corner and what it has counted. --%>
            <div
              :if={@camera?}
              id="pose-tracker"
              phx-hook="PoseTracker"
              phx-update="ignore"
              class="video-camera"
            >
              <video
                id="pose-tracker-preview"
                class="absolute inset-0 h-full w-full object-cover scale-x-[-1]"
                muted
                playsinline
                aria-hidden="true"
              ></video>
              <canvas
                id="pose-tracker-canvas"
                class="absolute inset-0 h-full w-full"
                aria-hidden="true"
              ></canvas>
              <p class="video-camera-count qs-tabular" role="status">
                <span class="sr-only">Reps counted:</span>
                <span id="video-camera-count">0</span>
              </p>
            </div>
          </div>

          <div
            id="video-watch-actions"
            class="video-watch-actions"
            role="group"
            aria-label="Session actions"
          >
            <%!-- Armed, the hook ends the video on the second tap, with how far it got. --%>
            <button
              id="video-finish-early"
              type="button"
              phx-click={if(@armed != "finish", do: "arm")}
              phx-value-choice="finish"
              phx-click-away={@armed == "finish" && "disarm"}
              aria-pressed={to_string(@armed == "finish")}
              aria-label={if(@armed == "finish", do: "Tap again to finish", else: "Finish early")}
              title={if(@armed == "finish", do: "Tap again to finish", else: "Finish early")}
              class="video-chip"
            >
              <.icon name="hero-flag" class="size-6" />
            </button>
            <button
              id="video-abort-btn"
              type="button"
              phx-click={if(@armed == "abort", do: "discard", else: "arm")}
              phx-value-choice="abort"
              phx-click-away={@armed == "abort" && "disarm"}
              aria-pressed={to_string(@armed == "abort")}
              aria-label={if(@armed == "abort", do: "Tap again to abort", else: "Abort workout")}
              title={if(@armed == "abort", do: "Tap again to abort", else: "Abort workout")}
              class="video-chip"
            >
              <.icon name="hero-x-mark" class="size-6" />
            </button>
          </div>
        </section>

        <div :if={@finished?} id="video-finish">
          <SessionComponents.completion_review
            hidden={false}
            form={@form}
            name={@video.name}
            events={@events}
            count={@reps}
            mood={@mood}
            tags={@tags}
            source={count_source(@counted_reps, @reps)}
            armed={if(@armed == "delete", do: "delete")}
          >
            <:meta>
              <span :if={@video.burpee_count}>of {@video.burpee_count} reps · </span>{Fmt.duration_sec(
                @watched_sec
              )} of {Fmt.duration_sec(@video.duration_sec)}
            </:meta>
          </SessionComponents.completion_review>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
