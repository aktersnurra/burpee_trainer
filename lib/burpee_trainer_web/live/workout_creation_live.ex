defmodule BurpeeTrainerWeb.WorkoutCreationLive do
  @moduledoc "Focused configuration and review of an owned, durable draft."
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Coach, Workouts}
  alias BurpeeTrainerWeb.{CreationParameters, WorkoutDraftStructure}

  @impl true
  def mount(_params, _session, socket) do
    parameters = %CreationParameters{}

    {:ok,
     assign(socket,
       parameters: parameters,
       form: to_form(CreationParameters.changeset(parameters, %{})),
       draft: nil,
       stage: :configure,
       editor: nil,
       editor_form: to_form(%{"text" => ""}, as: :editor),
       busy: false,
       error: nil,
       client_session_id: Ecto.UUID.generate()
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    with {id, ""} when id > 0 <- Integer.parse(id),
         {:ok, draft} <- Workouts.get_draft(socket.assigns.current_user, id) do
      {:noreply, show_draft(socket, draft)}
    else
      _ -> {:noreply, push_navigate(socket, to: ~p"/workouts")}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event(_event, _params, %{assigns: %{busy: true}} = socket), do: {:noreply, socket}

  def handle_event("change", %{"creation_parameters" => attrs}, socket) do
    {:noreply, change_parameters(socket, attrs)}
  end

  def handle_event("choose", %{"field" => field, "value" => value}, socket) do
    {:noreply, change_parameters(socket, %{field => value})}
  end

  def handle_event("step", %{"field" => field, "direction" => direction}, socket)
      when field in ["duration", "reps"] and direction in ["increase", "decrease"] do
    delta = if direction == "increase", do: 1, else: -1
    parameters = socket.assigns.parameters

    attrs =
      case field do
        "duration" ->
          {:ok, seconds} = CreationParameters.duration_seconds(parameters.duration)

          %{
            "duration" =>
              CreationParameters.duration_label(max(1, min(86_400, seconds + delta * 60)))
          }

        "reps" ->
          %{"reps" => max(1, min(100_000, parameters.reps + delta * 5))}
      end

    {:noreply, change_parameters(socket, attrs)}
  end

  def handle_event("configure", _params, socket) do
    {:noreply, assign(socket, stage: :configure, error: nil)}
  end

  def handle_event("open_note", _params, socket) do
    {:noreply, open_editor(socket, :note, socket.assigns.parameters.note || "")}
  end

  def handle_event("open_refine", _params, %{assigns: %{draft: draft}} = socket)
      when not is_nil(draft) do
    {:noreply, open_editor(socket, :refine, "")}
  end

  def handle_event("close_editor", _params, socket), do: {:noreply, close_editor(socket)}

  def handle_event(
        "save_editor",
        %{"editor" => %{"text" => text}},
        %{assigns: %{editor: :note}} = socket
      ) do
    changeset =
      CreationParameters.changeset(socket.assigns.parameters, %{note: String.trim(text)})

    case Ecto.Changeset.apply_action(changeset, :validate) do
      {:ok, parameters} ->
        {:noreply,
         socket |> assign(parameters: parameters, form: to_form(changeset)) |> close_editor()}

      {:error, _} ->
        {:noreply, assign(socket, error: "Keep the note to 300 characters.")}
    end
  end

  def handle_event(
        "save_editor",
        %{"editor" => %{"text" => text}},
        %{assigns: %{editor: :refine}} = socket
      ) do
    text = String.trim(text)

    if text == "" or String.length(text) > 500 or byte_size(text) > 4_000 do
      {:noreply, assign(socket, error: "Enter what should change, up to 500 characters.")}
    else
      user = socket.assigns.current_user
      draft = socket.assigns.draft

      {:noreply,
       socket
       |> assign(busy: true, error: nil)
       |> start_async(:author, fn -> Coach.refine_draft(user, draft.id, text) end)}
    end
  end

  def handle_event("generate", %{"creation_parameters" => attrs}, socket) do
    changeset = CreationParameters.changeset(socket.assigns.parameters, attrs)

    case Ecto.Changeset.apply_action(changeset, :validate) do
      {:ok, parameters} ->
        user = socket.assigns.current_user
        request = CreationParameters.request(parameters)
        draft = socket.assigns.draft

        {:noreply,
         socket
         |> assign(parameters: parameters, form: to_form(changeset), busy: true, error: nil)
         |> start_async(:author, fn ->
           if draft,
             do: Coach.refine_draft(user, draft.id, request),
             else: Coach.create_draft(user, request)
         end)}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           form: to_form(changeset),
           error: "Enter a duration as minutes:seconds and a positive rep count."
         )}
    end
  end

  def handle_event(
        "start",
        %{"client-session-id" => token},
        %{assigns: %{draft: draft, stage: :draft}} = socket
      )
      when not is_nil(draft) do
    with true <- token == socket.assigns.client_session_id,
         {:ok, session} <-
           Workouts.publish_and_start_draft(socket.assigns.current_user, draft, token) do
      {:noreply, push_navigate(socket, to: ~p"/session/#{session.id}")}
    else
      _ ->
        {:noreply,
         assign(socket,
           error: "This draft changed or is no longer available. Reopen it from Library."
         )}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:author, {:ok, {:ok, draft}}, socket) do
    {:noreply,
     socket
     |> assign(busy: false)
     |> close_editor()
     |> show_draft(draft)
     |> push_patch(to: ~p"/workouts/drafts/#{draft.id}")}
  end

  def handle_async(:author, _failure, socket) do
    {:noreply,
     assign(socket,
       busy: false,
       error: "Could not generate this workout. Your changes have been kept."
     )}
  end

  defp change_parameters(socket, attrs) do
    changeset = CreationParameters.changeset(socket.assigns.parameters, attrs)

    parameters =
      if changeset.valid?,
        do: Ecto.Changeset.apply_changes(changeset),
        else: socket.assigns.parameters

    assign(socket,
      parameters: parameters,
      form: to_form(changeset),
      error: if(changeset.valid?, do: nil, else: "Check the duration and rep count.")
    )
  end

  defp show_draft(socket, draft) do
    parameters = CreationParameters.from_draft(draft, socket.assigns.parameters)

    assign(socket,
      draft: draft,
      parameters: parameters,
      form: to_form(CreationParameters.changeset(parameters, %{})),
      stage: :draft,
      error: nil
    )
  end

  defp open_editor(socket, kind, text) do
    assign(socket, editor: kind, editor_form: to_form(%{"text" => text}, as: :editor), error: nil)
  end

  defp close_editor(socket), do: assign(socket, editor: nil, error: nil)

  attr(:field, :string, required: true)
  attr(:options, :list, required: true)
  attr(:selected, :string, required: true)
  attr(:busy, :boolean, required: true)
  attr(:label, :string, required: true)

  defp choices(assigns) do
    ~H"""
    <div class="creation-choices" role="group" aria-label={@label}>
      <button :for={{value, label} <- @options} id={"choice-#{@field}-#{value}"} type="button"
        phx-click="choose" phx-value-field={@field} phx-value-value={value}
        aria-pressed={to_string(@selected == value)} disabled={@busy}>{label}</button>
    </div>
    """
  end
end
