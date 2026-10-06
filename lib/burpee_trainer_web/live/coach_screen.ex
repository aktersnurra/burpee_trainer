defmodule BurpeeTrainerWeb.CoachScreen do
  @moduledoc "Coach summary and saved guidance."

  use BurpeeTrainerWeb, :html
  import Phoenix.LiveView

  alias BurpeeTrainer.Coach.Guidance
  alias BurpeeTrainerWeb.HomeCoachComponents

  def initialize(socket) do
    socket
    |> assign(
      coach_return_to: ~p"/",
      coach_open?: false,
      coach_guidance_form: to_form(%{"text" => ""}, as: :coach_guidance),
      coach_guidance_status: nil,
      coach_summary: "",
      coach_details_open?: false,
      coach_guidance_edit_id: nil,
      coach_guidance_edit_form: to_form(%{"text" => ""}, as: :coach_memory)
    )
    |> stream_configure(:coach_guidance_entries, dom_id: &"history-coach-entry-#{&1.id}")
    |> stream(:coach_guidance_entries, Guidance.list(socket.assigns.current_scope))
    |> refresh_coach_guidance()
  end

  def open(socket, params) do
    socket
    |> assign(
      coach_open?: true,
      coach_return_to: if(params["from"] == "history", do: ~p"/history", else: ~p"/")
    )
    |> refresh_coach_guidance()
  end

  defp refresh_coach_guidance(socket) do
    entries = Guidance.list(socket.assigns.current_scope)

    summary =
      entries
      |> Enum.filter(&(&1.kind in ["pending", "lasting", "temporary"]))
      |> Enum.take(12)
      |> Enum.map(&(&1.summary || &1.text))
      |> Enum.uniq()
      |> Enum.join("\n")

    socket
    |> assign(coach_summary: summary)
    |> stream(:coach_guidance_entries, entries, reset: true)
  end

  def handle_event("close_coach", _, socket),
    do: {:noreply, push_patch(socket, to: socket.assigns.coach_return_to)}

  def handle_event("coach_details_toggle", _, socket),
    do: {:noreply, assign(socket, coach_details_open?: not socket.assigns.coach_details_open?)}

  def handle_event("coach_guidance_change", %{"coach_guidance" => %{"text" => text}}, socket)
      when is_binary(text) do
    {:noreply,
     assign(socket,
       coach_guidance_form: to_form(%{"text" => text}, as: :coach_guidance),
       coach_guidance_status: nil
     )}
  end

  def handle_event("coach_guidance_submit", %{"coach_guidance" => %{"text" => text}}, socket)
      when is_binary(text) do
    case Guidance.add(socket.assigns.current_scope, text) do
      {:ok, entry} ->
        _ = Guidance.start_review(entry)

        {:noreply,
         socket
         |> assign(:coach_guidance_form, to_form(%{"text" => ""}, as: :coach_guidance))
         |> assign(:coach_guidance_status, "Saved for your coach.")
         |> refresh_coach_guidance()}

      {:error, :invalid_text} ->
        {:noreply,
         socket
         |> assign(:coach_guidance_form, to_form(%{"text" => text}, as: :coach_guidance))
         |> assign(:coach_guidance_status, "Enter an instruction of up to 1,000 characters.")}
    end
  end

  def handle_event("coach_guidance_remove", %{"id" => raw}, socket) when is_binary(raw) do
    with {id, ""} <- Integer.parse(raw),
         :ok <- Guidance.remove(socket.assigns.current_scope, id) do
      {:noreply,
       socket
       |> assign(coach_guidance_edit_id: nil, coach_guidance_status: "Removed from coach memory.")
       |> refresh_coach_guidance()}
    else
      _ -> {:noreply, assign(socket, :coach_guidance_status, "Could not remove that entry.")}
    end
  end

  def handle_event("coach_guidance_edit", %{"id" => raw}, socket) when is_binary(raw) do
    with {id, ""} <- Integer.parse(raw),
         entry when not is_nil(entry) <-
           Enum.find(Guidance.list(socket.assigns.current_scope), &(&1.id == id)) do
      {:noreply,
       socket
       |> assign(
         coach_guidance_edit_id: id,
         coach_guidance_edit_form: to_form(%{"text" => entry.text}, as: :coach_memory)
       )
       |> refresh_coach_guidance()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("coach_guidance_edit_change", %{"coach_memory" => params}, socket)
      when is_map(params) do
    {:noreply, assign(socket, coach_guidance_edit_form: to_form(params, as: :coach_memory))}
  end

  def handle_event("coach_guidance_edit_cancel", _, socket) do
    {:noreply, socket |> assign(coach_guidance_edit_id: nil) |> refresh_coach_guidance()}
  end

  def handle_event("coach_guidance_edit_save", %{"coach_memory" => %{"text" => text}}, socket)
      when is_binary(text) do
    case Guidance.update(
           socket.assigns.current_scope,
           socket.assigns.coach_guidance_edit_id,
           text
         ) do
      {:ok, entry} ->
        _ = Guidance.start_review(entry)

        {:noreply,
         socket
         |> assign(coach_guidance_edit_id: nil, coach_guidance_status: "Saved.")
         |> refresh_coach_guidance()}

      _ ->
        {:noreply,
         assign(socket,
           coach_guidance_status: "Enter info of up to 1,000 characters.",
           coach_guidance_edit_form: to_form(%{"text" => text}, as: :coach_memory)
         )}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  def screen(assigns) do
    ~H"""
    <main id="coach-page" class="mx-auto w-full max-w-3xl px-5 py-10 sm:px-8 sm:py-16">
      <HomeCoachComponents.panel state={assigns} />
    </main>
    """
  end
end
