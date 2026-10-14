defmodule BurpeeTrainerWeb.HomeCoach do
  @moduledoc """
  The coach on Home: once today's training is done, its note, the conversation and the
  owner-editable bounded notebook sit under the result.
  """
  use BurpeeTrainerWeb, :html
  import Phoenix.LiveView
  alias BurpeeTrainer.Coach.{Agent, Exchange, Notebook}
  alias BurpeeTrainer.Goals

  def initialize(socket) do
    socket
    |> assign(
      coach_details_open?: false,
      coach_message_form: to_form(%{"text" => ""}, as: :coach_message),
      coach_busy?: false,
      coach_reply: nil,
      coach_pending_message: nil,
      coach_status: nil
    )
    |> stream_configure(:coach_goals, dom_id: &"home-coach-goal-#{&1.id}")
    |> refresh()
  end

  # Coach lists only goals waiting on the owner; active ones read on Progress.
  defp refresh(socket) do
    notebook = Notebook.get(socket.assigns.current_scope)
    goals = Goals.list(socket.assigns.current_scope)

    socket
    |> assign(
      coach_exchange: Exchange.latest(socket.assigns.current_scope),
      coach_notebook_seen: notebook.updated_at,
      coach_notebook_form: to_form(%{"text" => notebook.body}, as: :coach_notebook)
    )
    |> stream(:coach_goals, Enum.filter(goals, &(&1.status == :proposed)), reset: true)
  end

  def handle_event("coach_details_toggle", _, socket),
    do: {:noreply, assign(socket, coach_details_open?: not socket.assigns.coach_details_open?)}

  def handle_event("coach_message_change", %{"coach_message" => %{"text" => text}}, socket)
      when is_binary(text),
      do:
        {:noreply,
         assign(socket, coach_message_form: to_form(%{"text" => text}, as: :coach_message))}

  def handle_event("coach_message", %{"coach_message" => %{"text" => text}}, socket)
      when is_binary(text) do
    text = String.trim(text)

    cond do
      socket.assigns.coach_busy? ->
        {:noreply, socket}

      text == "" or String.length(text) > 1000 ->
        {:noreply,
         assign(socket,
           coach_status: "Enter a message of up to 1,000 characters.",
           coach_message_form: to_form(%{"text" => text}, as: :coach_message)
         )}

      true ->
        scope = socket.assigns.current_scope

        {:noreply,
         socket
         |> assign(
           coach_busy?: true,
           coach_status: nil,
           coach_pending_message: text,
           coach_message_form: to_form(%{"text" => text}, as: :coach_message)
         )
         |> start_async(:coach_reply, fn -> Agent.run(scope, :coach_page, text) end)}
    end
  end

  # A one-tap reply sends its words as a message.
  def handle_event("coach_quick_reply", %{"text" => text}, socket) when is_binary(text),
    do: handle_event("coach_message", %{"coach_message" => %{"text" => text}}, socket)

  def handle_event("coach_notebook_change", %{"coach_notebook" => %{"text" => text}}, socket)
      when is_binary(text),
      do:
        {:noreply,
         assign(socket, coach_notebook_form: to_form(%{"text" => text}, as: :coach_notebook))}

  def handle_event("coach_notebook_save", %{"coach_notebook" => %{"text" => text}}, socket)
      when is_binary(text), do: save_notebook(socket, text)

  def handle_event("coach_notebook_clear", _, socket), do: save_notebook(socket, "")

  def handle_event(event, %{"id" => raw}, socket)
      when event in ["coach_goal_confirm", "coach_goal_dismiss"] and is_binary(raw) do
    with {id, ""} <- Integer.parse(raw),
         {:ok, _} <-
           if(event == "coach_goal_confirm",
             do: Goals.confirm(socket.assigns.current_scope, id),
             else: Goals.dismiss(socket.assigns.current_scope, id)
           ) do
      {:noreply, refresh(socket)}
    else
      _ -> {:noreply, assign(socket, coach_status: "Goal not available.")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp save_notebook(socket, text) do
    case Notebook.write(socket.assigns.current_scope, text, socket.assigns.coach_notebook_seen) do
      {:ok, _} ->
        {:noreply, socket |> assign(coach_status: "Saved.") |> refresh()}

      {:error, :stale_notebook} ->
        {:noreply,
         socket
         |> refresh()
         |> assign(coach_status: "Updated by your coach; review and save again.")}

      {:error, :too_long} ->
        {:noreply, assign(socket, coach_status: "Notebook exceeds 4,000 characters.")}
    end
  end

  def handle_async(:coach_reply, {:ok, {:ok, %{reply: reply} = result}}, socket) do
    # The exchange is kept so it is still there after a reload; failing to keep it loses
    # nothing the owner sees now.
    Exchange.record(
      socket.assigns.current_scope,
      socket.assigns.coach_pending_message,
      reply,
      Map.get(result, :suggestions, [])
    )

    {:noreply,
     socket
     |> assign(
       coach_busy?: false,
       # The reply reads in the exchange; this line is for failures only.
       coach_reply: nil,
       coach_message_form: to_form(%{"text" => ""}, as: :coach_message)
     )
     |> refresh()}
  end

  def handle_async(:coach_reply, _, socket),
    do:
      {:noreply,
       assign(socket, coach_busy?: false, coach_reply: "Coach unavailable. Try again later.")}
end
