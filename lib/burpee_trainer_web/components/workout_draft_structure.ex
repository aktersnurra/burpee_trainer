defmodule BurpeeTrainerWeb.WorkoutDraftStructure do
  @moduledoc "Literal work and recovery from the stored execution program."
  use BurpeeTrainerWeb, :html

  alias BurpeeTrainerWeb.CreationParameters

  attr(:plan, :any, required: true)

  def structure(assigns) do
    events = Enum.map(assigns.plan.program_json["events"], &display_event/1)

    last_work_index =
      events
      |> Enum.with_index()
      |> Enum.filter(fn {e, _} -> e["kind"] == "work" end)
      |> List.last()
      |> elem(1)

    {sequence, trailing} = Enum.split(events, last_work_index + 1)
    total = Enum.sum(Enum.map(sequence, & &1["duration_sec"]))

    {numbered, _} =
      Enum.map_reduce(sequence, 0, fn event, number ->
        number = if event["kind"] == "work", do: number + 1, else: number
        {Map.put(event, "set_number", number), number}
      end)

    assigns =
      assign(assigns,
        events: numbered,
        sequence_duration: total,
        final_recovery: Enum.sum(Enum.map(trailing, & &1["duration_sec"]))
      )

    ~H"""
    <section id="draft-structure" class="draft-structure" aria-label="Workout structure">
      <div
        id="draft-timeline"
        class="draft-timeline"
        role="img"
        aria-label="Dark blocks are sets; light blocks are recovery. Exact intervals follow."
      >
        <span
          :for={{event, index} <- Enum.with_index(@events)}
          id={"draft-interval-#{index}"}
          class={[
            "draft-interval",
            event["kind"] == "work" && "draft-interval-work",
            event["kind"] == "rest" && "draft-interval-rest"
          ]}
          data-kind={event["kind"]}
          data-duration={event["duration_sec"]}
          style={"flex-grow: #{event["duration_sec"]};"}
          aria-hidden="true"
        >
        </span>
      </div>
      <div class="draft-legend" aria-hidden="true">
        <span><i class="draft-key-work"></i> Set</span>
        <span><i class="draft-key-rest"></i> Recovery</span>
      </div>
      <ol id="draft-intervals" class="draft-intervals">
        <li :for={{event, index} <- Enum.with_index(@events)} id={"draft-detail-#{index}"}>
          <%= if event["kind"] == "work" do %>
            <span>Set {event["set_number"]}</span>
            <span>{event["reps"]} reps · {number(event["sec_per_rep"])} s/rep</span>
          <% else %>
            <span>Recovery</span>
            <span>{seconds(event["duration_sec"])}</span>
          <% end %>
        </li>
      </ol>
      <p :if={@final_recovery > 0} id="draft-final-recovery" class="draft-final-recovery">
        Final recovery · {seconds(@final_recovery)}
      </p>
    </section>
    """
  end

  defp display_event(%{"kind" => "work"} = event),
    do: Map.put(event, "sec_per_rep", event["sec_per_rep_us"] / 1_000_000)

  defp display_event(%{"kind" => "rest"} = event),
    do: Map.put(event, "duration_sec", event["duration_ms"] / 1_000)

  defp number(value) when is_integer(value), do: Integer.to_string(value)

  defp number(value),
    do:
      value
      |> :erlang.float_to_binary(decimals: 6)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")

  defp seconds(value) when value == round(value), do: CreationParameters.duration_label(value)
  defp seconds(value), do: "#{number(value)} s"
end
