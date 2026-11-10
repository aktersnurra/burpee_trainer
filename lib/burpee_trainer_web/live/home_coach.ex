defmodule BurpeeTrainerWeb.HomeCoach do
  @moduledoc """
  The coach on Home and on the Coach page: once today's training is done, the coach sits open
  under Home's result: this week's window, then the conversation opened by the coach's note,
  with what the coach noted or forgot about you between the exchanges. The Coach page adds
  what it remembers, in a sheet.
  """
  use BurpeeTrainerWeb, :html
  import Phoenix.LiveView
  alias BurpeeTrainer.Coach.{Agent, Exchange, Memory, MemoryJob}
  alias BurpeeTrainer.{Goals, WeekWindow}
  alias BurpeeTrainerWeb.ReplyStream

  def initialize(socket) do
    socket
    |> assign(
      coach_message_form: to_form(%{"text" => ""}, as: :coach_message),
      coach_busy?: false,
      coach_reply: nil,
      coach_pending_message: nil,
      # Whether the coach has started writing its reply (the words are `:coach_reply_pieces`).
      coach_streaming?: false,
      coach_status: nil,
      coach_memory_open?: false,
      # Whether the coach wrote to its memory as it talked on this page, so leaving the Coach
      # page rewrites the summary that reads from it.
      coach_memory_changed?: false
    )
    |> stream_configure(:coach_goals, dom_id: &"home-coach-goal-#{&1.id}")
    |> ReplyStream.initialize(:coach_reply_pieces)
    |> refresh()
  end

  # Reloads the coach's state, as after a reply or a change to its memory. Coach lists
  # only goals waiting on the owner; active ones read on Progress.
  def refresh(socket) do
    scope = socket.assigns.current_scope
    goals = Goals.list(scope)

    socket
    |> assign(
      coach_thread: this_week(scope),
      coach_memory_changes: Memory.changes_since(scope, week_start_utc(scope)),
      coach_memory: Memory.stores(scope),
      coach_week: week_window(scope, socket.assigns[:slot])
    )
    |> stream(:coach_goals, Enum.filter(goals, &(&1.status == :proposed)), reset: true)
  end

  # What the coach remembers, opened on asking; to change a line, the owner tells the coach.
  def handle_event("coach_memory_toggle", _, socket),
    do: {:noreply, assign(socket, coach_memory_open?: not socket.assigns.coach_memory_open?)}

  def handle_event("coach_memory_close", _, socket),
    do: {:noreply, assign(socket, coach_memory_open?: false)}

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
        history = Enum.map(socket.assigns.coach_thread, &{&1.message, &1.reply})
        live_view = self()

        {:noreply,
         socket
         |> assign(
           coach_busy?: true,
           coach_status: nil,
           coach_streaming?: false,
           coach_pending_message: text,
           # The message moves into the thread; the box empties, as in the studio.
           coach_message_form: to_form(%{"text" => ""}, as: :coach_message)
         )
         |> start_async(:coach_reply, fn ->
           Agent.run(scope, :coach_page, text,
             history: history,
             on_reply: &send(live_view, {:coach_streaming, &1})
           )
         end)}
    end
  end

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

  # The reply as the coach writes it; one arriving after the answer is in changes nothing.
  def handle_info({:coach_streaming, text}, %{assigns: %{coach_busy?: true}} = socket),
    do:
      {:noreply,
       socket
       |> ReplyStream.show(:coach_reply_pieces, text)
       |> assign(coach_streaming?: true)}

  def handle_info({:coach_streaming, _text}, socket), do: {:noreply, socket}

  # This week's conversation; it starts over with the week, as the report does.
  defp this_week(scope), do: Exchange.since(scope, week_start_utc(scope))

  # What is done this week and what is left of its target, for the card's front.
  defp week_window(_scope, nil), do: []
  defp week_window(scope, slot), do: WeekWindow.this_week(scope, slot.weekly_target_sec)

  defp week_start_utc(scope), do: WeekWindow.week_start_utc(scope)

  def handle_async(:coach_reply, {:ok, {:ok, %{reply: reply} = result}}, socket) do
    # The exchange is kept so it is still there after a reload; failing to keep it loses
    # nothing the owner sees now.
    scope = socket.assigns.current_scope

    with {:ok, exchange} <-
           Exchange.record(scope, socket.assigns.coach_pending_message, reply) do
      # The coach keeps its memory as it talks; when it wrote nothing, a review reads the
      # exchange afterwards. What it notes reads in the thread.
      if not Map.get(result, :memory_written?, false),
        do: MemoryJob.admit_exchange(scope, exchange)
    end

    {:noreply,
     socket
     |> ReplyStream.show(:coach_reply_pieces, nil)
     |> assign(
       coach_busy?: false,
       coach_pending_message: nil,
       coach_streaming?: false,
       # The reply reads in the conversation; this line is for failures only.
       coach_reply: nil,
       coach_message_form: to_form(%{"text" => ""}, as: :coach_message),
       coach_memory_changed?:
         socket.assigns.coach_memory_changed? or Map.get(result, :memory_written?, false)
     )
     |> refresh()}
  end

  # A message the coach could not answer goes back in the box, to send again.
  def handle_async(:coach_reply, _, socket),
    do:
      {:noreply,
       socket
       |> ReplyStream.show(:coach_reply_pieces, nil)
       |> assign(
         coach_busy?: false,
         coach_pending_message: nil,
         coach_streaming?: false,
         coach_message_form:
           to_form(%{"text" => socket.assigns.coach_pending_message}, as: :coach_message),
         coach_reply: "Coach unavailable. Try again later."
       )}
end
