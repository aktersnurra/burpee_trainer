defmodule BurpeeTrainer.Coach.ProposalEdit do
  @moduledoc """
  Pure: a number on a proposal changed by hand, with no call to the coach. The athlete steps
  the reps or the beat of some sets; the rests are fitted again by `RestFitter` so the
  workout keeps its length, each rest keeping its share of the recovery it had. The request
  follows: its total reps, its ordered sets when it named them, its pace when it named one.

  Refused (`:error`) when the change cannot fit, when a set would go below one rep or a beat
  below a second or shorter than its movement, and for workouts with timed pauses, whose
  phases a hand edit does not reason about.
  """

  alias BurpeeTrainer.Coach.{RestFitter, WorkoutRequest}

  @beat_step_ms 500
  @min_beat_ms 1_000

  @type field :: :reps | :every

  @doc """
  Steps `field` of the work events at `indices` (positions in the definition's events) by one
  step in `dir`. Returns the fitted definition attrs and the request it now meets.
  """
  @spec apply(map(), WorkoutRequest.t(), [non_neg_integer()], field(), -1 | 1) ::
          {:ok, map(), WorkoutRequest.t()} | :error
  def apply(definition, %WorkoutRequest{timed_rests: []} = request, [_ | _] = indices, field, dir)
      when field in [:reps, :every] and dir in [-1, 1] do
    events = definition["events"]

    with true <- is_list(events) and events != [],
         true <- Enum.all?(indices, &match?(%{"kind" => "work"}, Enum.at(events, &1))),
         {:ok, events} <- step(events, MapSet.new(indices), field, dir),
         {:ok, layout} <- layout(events, definition),
         {:ok, request} <- follow(request, events),
         {:ok, attrs} <- RestFitter.fit(request, layout) do
      {:ok, rename(attrs, definition), request}
    else
      _ -> :error
    end
  end

  def apply(_definition, _request, _indices, _field, _dir), do: :error

  defp step(events, indices, field, dir) do
    events
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {event, index}, {:ok, acc} ->
      if MapSet.member?(indices, index) do
        case step_event(event, field, dir) do
          {:ok, event} -> {:cont, {:ok, [event | acc]}}
          :error -> {:halt, :error}
        end
      else
        {:cont, {:ok, [event | acc]}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      :error -> :error
    end
  end

  defp step_event(%{"reps" => reps} = event, :reps, dir) when reps + dir >= 1,
    do: {:ok, %{event | "reps" => reps + dir}}

  # The beat moves by half a second; an unbroken set moves with it, since its movement is
  # its beat.
  defp step_event(%{"sec_per_rep" => beat, "sec_per_burpee" => move} = event, :every, dir) do
    beat_ms = ms(beat)
    next_ms = beat_ms + dir * @beat_step_ms

    cond do
      next_ms < @min_beat_ms ->
        :error

      beat_ms == ms(move) ->
        {:ok, %{event | "sec_per_rep" => sec(next_ms), "sec_per_burpee" => sec(next_ms)}}

      next_ms < ms(move) ->
        :error

      true ->
        {:ok, %{event | "sec_per_rep" => sec(next_ms)}}
    end
  end

  defp step_event(_event, _field, _dir), do: :error

  # One phase: the sets in order, and between two sets its rest as a share by its length now,
  # so the recovery is shared as it was; no rest stays none.
  defp layout(events, definition) do
    with %{"kind" => "work"} <- List.first(events),
         %{"kind" => "work"} <- List.last(events) do
      {sets, rests} =
        events
        |> Enum.chunk_by(&(&1["kind"] == "work"))
        |> Enum.flat_map(fn
          [%{"kind" => "work"} | _] = works -> Enum.map(works, &{:set, &1})
          rests -> [{:rest, rests |> Enum.map(&ms(&1["duration_sec"])) |> Enum.sum()}]
        end)
        |> gaps()

      {:ok,
       %{
         "name" => definition["name"],
         "rationale" => definition["rationale"],
         "phases" => [%{"sets" => sets, "rests" => rests}]
       }}
    else
      _ -> :error
    end
  end

  # Sets and the rest after each but the last; two sets in a row have a rest of zero.
  defp gaps(items) do
    {sets, rests, _} =
      Enum.reduce(items, {[], [], nil}, fn
        {:set, work}, {sets, rests, previous} ->
          rests = if previous == :set, do: [%{"sec" => 0} | rests], else: rests
          {[Map.take(work, ~w[reps sec_per_rep sec_per_burpee]) | sets], rests, :set}

        {:rest, 0}, {sets, rests, _previous} ->
          {sets, [%{"sec" => 0} | rests], :rest}

        {:rest, rest_ms}, {sets, rests, _previous} ->
          {sets, [%{"share" => rest_ms} | rests], :rest}
      end)

    {Enum.reverse(sets), Enum.reverse(rests)}
  end

  defp follow(request, events) do
    work = Enum.filter(events, &(&1["kind"] == "work"))
    reps = Enum.map(work, & &1["reps"])

    pace =
      case Enum.uniq_by(work, &ms(&1["sec_per_burpee"])) do
        [one] -> one["sec_per_burpee"]
        _ -> nil
      end

    attrs =
      WorkoutRequest.to_map(request)
      |> Map.put("target_reps", Enum.sum(reps))
      |> then(&if(request.set_reps == [], do: &1, else: Map.put(&1, "set_reps", reps)))
      |> then(
        &if(request.requested_pace_sec, do: Map.put(&1, "requested_pace_sec", pace), else: &1)
      )
      |> then(fn attrs ->
        if request.max_set_reps,
          do: Map.put(attrs, "max_set_reps", min(request.max_set_reps, Enum.sum(reps))),
          else: attrs
      end)

    WorkoutRequest.new(attrs)
  end

  # A name that says the total says the new one.
  defp rename(attrs, definition) do
    old = definition["target_reps"]
    new = attrs["target_reps"]

    name =
      if is_binary(attrs["name"]) and old != new,
        do: Regex.replace(~r/\b#{old}\b/, attrs["name"], Integer.to_string(new)),
        else: attrs["name"]

    %{attrs | "name" => name}
  end

  defp ms(seconds), do: round(seconds * 1_000)
  defp sec(ms) when rem(ms, 1_000) == 0, do: div(ms, 1_000)
  defp sec(ms), do: ms / 1_000
end
