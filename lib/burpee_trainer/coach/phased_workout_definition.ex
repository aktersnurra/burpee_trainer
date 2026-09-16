defmodule BurpeeTrainer.Coach.PhasedWorkoutDefinition do
  @moduledoc "Required-rest response shape for LLM-planned workouts."

  alias BurpeeTrainer.Coach.WorkoutRequest
  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition
  alias BurpeeTrainer.Workouts.Error

  @spec use_phases?(WorkoutRequest.t()) :: boolean()
  def use_phases?(%WorkoutRequest{recovery: "required"}), do: true
  def use_phases?(%WorkoutRequest{timed_rests: [_ | _]}), do: true

  def use_phases?(%WorkoutRequest{
        recovery: "optional",
        pacing_style: "unbroken",
        requested_pace_sec: pace,
        target_reps: reps,
        target_duration_sec: duration,
        set_reps: sets
      })
      when is_number(pace) and reps > 1 and duration > reps * pace,
      do: is_nil(sets) or length(sets) > 1

  def use_phases?(%WorkoutRequest{}), do: false

  @spec phase_budgets(WorkoutRequest.t()) :: [non_neg_integer()]
  def phase_budgets(%WorkoutRequest{timed_rests: [], target_duration_sec: _}), do: []

  def phase_budgets(%WorkoutRequest{} = request) do
    {last_end, reversed} =
      Enum.reduce(request.timed_rests, {0, []}, fn rest, {previous_end, budgets} ->
        {rest.start_sec + rest.duration_sec, [rest.start_sec - previous_end | budgets]}
      end)

    Enum.reverse([request.target_duration_sec - last_end | reversed])
  end

  @spec json_schema(WorkoutRequest.t()) :: map()
  def json_schema(%WorkoutRequest{} = request) do
    base = WorkoutDefinition.json_schema()
    [work, rest] = base["properties"]["events"]["items"]["anyOf"]

    pair = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["work", "rest_after"],
      "properties" => %{"work" => work, "rest_after" => rest}
    }

    phase = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["work_rest_pairs", "last_work"],
      "properties" => %{
        "work_rest_pairs" => %{"type" => "array", "items" => pair},
        "last_work" => work
      }
    }

    {names, fields} =
      Enum.reduce(1..rest_count(request), {[], %{}}, fn index, {names, fields} ->
        timed_rest = Enum.at(request.timed_rests, index - 1)

        rest_schema =
          if timed_rest do
            put_in(rest, ["properties", "duration_sec"], %{
              "type" => "number",
              "enum" => [timed_rest.duration_sec],
              "description" => "User-confirmed timed rest duration."
            })
          else
            rest
          end

        {names ++ ["phase_#{index}", "rest_#{index}"],
         Map.merge(fields, %{"phase_#{index}" => phase, "rest_#{index}" => rest_schema})}
      end)

    last_phase = "phase_#{rest_count(request) + 1}"

    %{
      base
      | "required" => Enum.reject(base["required"], &(&1 == "events")) ++ names ++ [last_phase],
        "properties" =>
          base["properties"]
          |> Map.delete("events")
          |> Map.merge(Map.put(fields, last_phase, phase))
    }
  end

  @spec flatten(WorkoutRequest.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def flatten(%WorkoutRequest{} = request, %{} = proposal) do
    if MapSet.new(Map.keys(proposal)) == MapSet.new(json_schema(request)["required"]) do
      result =
        Enum.reduce_while(1..(rest_count(request) + 1), {:ok, []}, fn index, {:ok, events} ->
          case phase_events(proposal["phase_#{index}"]) do
            {:ok, phase} ->
              if index <= rest_count(request) and is_map(proposal["rest_#{index}"]) do
                {:cont, {:ok, events ++ phase ++ [proposal["rest_#{index}"]]}}
              else
                if index > rest_count(request),
                  do: {:cont, {:ok, events ++ phase}},
                  else: {:halt, :error}
              end

            :error ->
              {:halt, :error}
          end
        end)

      case result do
        {:ok, events} ->
          {:ok,
           proposal
           |> Map.drop(phase_fields(request))
           |> Map.put("events", events)}

        :error ->
          invalid()
      end
    else
      invalid()
    end
  end

  def flatten(%WorkoutRequest{}, _proposal), do: invalid()

  defp phase_events(%{"work_rest_pairs" => pairs, "last_work" => last} = phase)
       when is_list(pairs) and is_map(last) do
    if MapSet.new(Map.keys(phase)) == MapSet.new(~w[work_rest_pairs last_work]) and
         Enum.all?(pairs, fn
           %{"work" => work, "rest_after" => rest} = pair ->
             is_map(work) and is_map(rest) and
               MapSet.new(Map.keys(pair)) == MapSet.new(~w[work rest_after])

           _ ->
             false
         end) do
      {:ok, Enum.flat_map(pairs, &[&1["work"], &1["rest_after"]]) ++ [last]}
    else
      :error
    end
  end

  defp phase_events(_), do: :error

  @spec phase_feedback(WorkoutRequest.t(), map()) :: String.t()
  def phase_feedback(%WorkoutRequest{} = request, %{} = proposal) do
    expected = phase_budgets(request)

    with false <- expected == [],
         {:ok, _} <- flatten(request, proposal),
         {:ok, durations} <- phase_durations(request, proposal) do
      " phase_seconds=#{inspect(durations)} expected=#{inspect(expected)}"
    else
      _ -> ""
    end
  end

  def phase_feedback(%WorkoutRequest{}, _proposal), do: ""

  defp phase_durations(request, proposal) do
    last_index = rest_count(request) + 1

    Enum.reduce_while(1..last_index, {:ok, []}, fn index, {:ok, durations} ->
      case phase_duration_us(proposal["phase_#{index}"], index == last_index) do
        :error ->
          {:halt, :error}

        microseconds ->
          seconds =
            if rem(microseconds, 1_000_000) == 0,
              do: div(microseconds, 1_000_000),
              else: microseconds / 1_000_000

          {:cont, {:ok, durations ++ [seconds]}}
      end
    end)
  end

  defp phase_duration_us(phase, terminal?) do
    with {:ok, events} <- phase_events(phase),
         true <- length(events) <= 512 do
      terminal_index = length(events) - 1

      events
      |> Enum.with_index()
      |> Enum.reduce_while(0, fn
        {%{"kind" => "work", "reps" => reps, "sec_per_rep" => pace, "sec_per_burpee" => active},
         index},
        total
        when is_integer(reps) and reps > 0 and is_number(pace) and pace > 0 and
               is_number(active) and active > 0 ->
          pace_us = round(pace * 1_000) * 1_000
          active_us = round(active * 1_000) * 1_000

          duration_us =
            if terminal? and index == terminal_index,
              do: (reps - 1) * pace_us + active_us,
              else: reps * pace_us

          {:cont, total + duration_us}

        {%{"kind" => "rest", "duration_sec" => seconds}, _index}, total
        when is_number(seconds) and seconds > 0 ->
          {:cont, total + round(seconds * 1_000) * 1_000}

        _invalid, _total ->
          {:halt, :error}
      end)
    else
      _ -> :error
    end
  end

  defp phase_fields(request) do
    Enum.flat_map(1..rest_count(request), fn index -> ["phase_#{index}", "rest_#{index}"] end) ++
      ["phase_#{rest_count(request) + 1}"]
  end

  defp rest_count(%WorkoutRequest{timed_rests: []}), do: 1
  defp rest_count(%WorkoutRequest{timed_rests: rests}), do: length(rests)

  defp invalid, do: {:error, Error.new(:invalid_workout_definition)}
end
