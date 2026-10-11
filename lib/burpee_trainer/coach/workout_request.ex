defmodule BurpeeTrainer.Coach.WorkoutRequest do
  @moduledoc "Confirmed constraints for one user-initiated workout authoring attempt."

  alias BurpeeTrainer.Workouts.Error

  @max_duration_sec 86_400
  @max_reps 100_000
  @max_rests 64
  @timing_tolerance_sec 10
  @fields ~w[burpee_type target_reps target_duration_sec pacing_style recovery timed_rests requested_pace_sec]

  @enforce_keys [
    :burpee_type,
    :target_reps,
    :target_duration_sec,
    :pacing_style,
    :recovery,
    :timed_rests,
    :requested_pace_sec
  ]
  defstruct @enforce_keys ++ [set_reps: []]

  @type t :: %__MODULE__{
          burpee_type: String.t(),
          target_reps: pos_integer(),
          target_duration_sec: pos_integer(),
          pacing_style: String.t(),
          recovery: String.t(),
          timed_rests: [map()],
          requested_pace_sec: number() | nil,
          set_reps: [pos_integer()]
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%{} = attrs) do
    with true <- MapSet.new(Map.keys(Map.delete(attrs, "set_reps"))) == MapSet.new(@fields),
         %{
           "burpee_type" => burpee_type,
           "target_reps" => reps,
           "target_duration_sec" => duration,
           "pacing_style" => style,
           "recovery" => recovery,
           "timed_rests" => rests,
           "requested_pace_sec" => pace
         } <- attrs,
         true <- burpee_type in ~w[six_count navy_seal],
         true <- is_integer(reps) and reps > 0 and reps <= @max_reps,
         true <- is_integer(duration) and duration > 0 and duration <= @max_duration_sec,
         true <- style in ~w[even unbroken],
         true <- recovery in ~w[required forbidden optional],
         true <- is_nil(pace) or (is_number(pace) and pace > 0 and pace <= @max_duration_sec),
         sets <- Map.get(attrs, "set_reps", []),
         true <-
           is_list(sets) and length(sets) <= 5_000 and
             Enum.all?(sets, &(is_integer(&1) and &1 > 0)) and
             (sets == [] or Enum.sum(sets) == reps),
         {:ok, rests} <- validate_rests(rests, duration, recovery) do
      {:ok,
       %__MODULE__{
         burpee_type: burpee_type,
         target_reps: reps,
         target_duration_sec: duration,
         pacing_style: style,
         recovery: recovery,
         timed_rests: rests,
         requested_pace_sec: pace,
         set_reps: sets
       }}
    else
      _ -> {:error, Error.new(:invalid_workout_definition)}
    end
  end

  def new(_attrs), do: {:error, Error.new(:invalid_workout_definition)}

  @spec timing_tolerance_sec() :: pos_integer()
  def timing_tolerance_sec, do: @timing_tolerance_sec

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request) do
    %{
      "burpee_type" => request.burpee_type,
      "target_reps" => request.target_reps,
      "target_duration_sec" => request.target_duration_sec,
      "pacing_style" => request.pacing_style,
      "recovery" => request.recovery,
      "timed_rests" =>
        Enum.map(request.timed_rests, fn rest ->
          %{"start_sec" => rest.start_sec, "duration_sec" => rest.duration_sec}
        end),
      "requested_pace_sec" => request.requested_pace_sec
    }
    |> then(fn attrs ->
      if request.set_reps == [], do: attrs, else: Map.put(attrs, "set_reps", request.set_reps)
    end)
  end

  @spec json_schema() :: map()
  def json_schema do
    %{
      type: "object",
      additionalProperties: false,
      required: @fields ++ ["set_reps"],
      properties: %{
        set_reps: %{
          type: "array",
          maxItems: 5_000,
          items: %{type: "integer", minimum: 1},
          description:
            "Reps of each set in order when the user states them, summing to target_reps; empty otherwise."
        },
        burpee_type: %{type: "string", enum: ~w[six_count navy_seal]},
        target_reps: %{type: "integer", minimum: 1, maximum: @max_reps},
        target_duration_sec: %{type: "integer", minimum: 1, maximum: @max_duration_sec},
        pacing_style: %{type: "string", enum: ~w[even unbroken]},
        recovery: %{type: "string", enum: ~w[required forbidden optional]},
        timed_rests: %{
          type: "array",
          maxItems: @max_rests,
          items: %{
            type: "object",
            additionalProperties: false,
            required: ~w[start_sec duration_sec],
            properties: %{
              start_sec: %{type: "integer", minimum: 0},
              duration_sec: %{type: "integer", minimum: 1}
            }
          }
        },
        requested_pace_sec: %{anyOf: [%{type: "number", exclusiveMinimum: 0}, %{type: "null"}]}
      }
    }
  end

  @spec validate_definition(t(), BurpeeTrainer.PlanCompiler.WorkoutDefinition.t()) ::
          :ok | {:error, Error.t(), String.t()}
  def validate_definition(%__MODULE__{} = request, definition) do
    cond do
      definition.target_reps != request.target_reps ->
        invalid_definition(
          "field=confirmed_target_reps actual=#{definition.target_reps} expected=#{request.target_reps}"
        )

      abs(definition.target_duration_sec - request.target_duration_sec) > @timing_tolerance_sec ->
        invalid_definition(
          "field=confirmed_target_duration_sec actual=#{definition.target_duration_sec} expected=#{request.target_duration_sec} tolerance_sec=#{@timing_tolerance_sec}"
        )

      Atom.to_string(definition.burpee_type) != request.burpee_type or
          Atom.to_string(definition.pacing_style) != request.pacing_style ->
        invalid_definition("field=confirmed_movement_or_style")

      request.set_reps != [] and
          definition.events |> Enum.filter(&(&1.kind == :work)) |> Enum.map(& &1.reps) !=
            request.set_reps ->
        invalid_definition("field=set_configuration ordered_reps_mismatch=true", %{
          field: :set_reps,
          actual_count: Enum.count(definition.events, &(&1.kind == :work)),
          expected_count: length(request.set_reps)
        })

      request.pacing_style == "unbroken" and
          Enum.any?(definition.events, fn event ->
            event.kind == :work and
                round(event.sec_per_rep * 1_000_000) != round(event.sec_per_burpee * 1_000_000)
          end) ->
        invalid_definition("field=unbroken continuous_sets_required=true")

      request.recovery == "forbidden" and Enum.any?(definition.events, &(&1.kind == :rest)) ->
        invalid_definition("field=events rest_forbidden=true")

      request.recovery == "required" and
          not Enum.any?(definition.events, &(&1.kind == :rest)) ->
        invalid_definition("field=events rest_events=0")

      request.recovery == "required" and adjacent_work_sets?(definition.events) ->
        invalid_definition("field=events adjacent_work_sets_without_rest=true")

      request.recovery == "required" and not between_set_recovery?(definition.events) ->
        invalid_definition("field=events between_set_recovery_missing=true")

      request.requested_pace_sec != nil and
          Enum.any?(definition.events, fn
            %{kind: :work, sec_per_burpee: active} ->
              round(active * 1_000_000) != round(request.requested_pace_sec * 1_000_000)

            %{kind: :rest} ->
              false
          end) ->
        invalid_definition("field=events requested_pace_sec=#{request.requested_pace_sec}")

      true ->
        validate_timed_rests(request, definition.events)
    end
  end

  defp adjacent_work_sets?(events) do
    events
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [left, right] -> left.kind == :work and right.kind == :work end)
  end

  defp between_set_recovery?(events) do
    Enum.reduce_while(events, {false, false}, fn
      %{kind: :work}, {true, true} ->
        {:halt, true}

      %{kind: :work}, _state ->
        {:cont, {true, false}}

      %{kind: :rest}, {seen_work?, _rest_since_work?} ->
        {:cont, {seen_work?, seen_work?}}
    end) == true
  end

  @doc "Actual pause starts and total lengths, in microseconds, without double-counting cadence tails."
  @spec rest_timeline([WorkoutDefinition.event()]) :: [{non_neg_integer(), pos_integer()}]
  def rest_timeline(events) do
    terminal_index = length(events) - 1

    {_elapsed, rests, _tail} =
      events
      |> Enum.with_index()
      |> Enum.reduce({0, [], 0}, fn
        {%{kind: :work, reps: reps, sec_per_rep: cadence, sec_per_burpee: active}, index},
        {elapsed, rests, _tail} ->
          cadence_us = round(cadence * 1_000_000)
          active_us = round(active * 1_000_000)

          duration_us =
            if index == terminal_index,
              do: (reps - 1) * cadence_us + active_us,
              else: reps * cadence_us

          {elapsed + duration_us, rests, max(cadence_us - active_us, 0)}

        {%{kind: :rest, duration_sec: seconds}, _index}, {elapsed, rests, tail_us} ->
          duration_us = round(seconds * 1_000) * 1_000

          pauses =
            case rests do
              [{start, previous} | remaining] when start + previous == elapsed ->
                [{start, previous + duration_us} | remaining]

              _ ->
                [{elapsed - tail_us, duration_us + tail_us} | rests]
            end

          {elapsed + duration_us, pauses, 0}
      end)

    Enum.reverse(rests)
  end

  defp validate_timed_rests(request, events) do
    result =
      Enum.reduce_while(request.timed_rests, {:ok, rest_timeline(events)}, fn rest,
                                                                              {:ok, remaining} ->
        expected_start = rest.start_sec * 1_000_000
        expected_duration = rest.duration_sec * 1_000_000

        case Enum.find_index(remaining, fn {start, duration} ->
               duration == expected_duration and
                 abs(start - expected_start) <= @timing_tolerance_sec * 1_000_000
             end) do
          nil -> {:halt, {:error, rest}}
          index -> {:cont, {:ok, Enum.drop(remaining, index + 1)}}
        end
      end)

    case result do
      {:ok, _remaining} ->
        :ok

      {:error, rest} ->
        invalid_definition(
          "field=events missing_timed_rest start_sec=#{rest.start_sec} duration_sec=#{rest.duration_sec} tolerance_sec=#{@timing_tolerance_sec}",
          %{field: :timed_rests, start_sec: rest.start_sec, duration_sec: rest.duration_sec}
        )
    end
  end

  defp invalid_definition(detail, context \\ %{}),
    do: {:error, Error.new(:invalid_workout_definition, context), detail}

  defp validate_rests(rests, duration, recovery)
       when is_list(rests) and length(rests) <= @max_rests do
    if recovery == "forbidden" and rests != [] do
      :error
    else
      rests
      |> Enum.reduce_while({:ok, [], 0}, fn
        %{"start_sec" => start_sec, "duration_sec" => seconds} = rest, {:ok, acc, previous_end}
        when map_size(rest) == 2 and is_integer(start_sec) and is_integer(seconds) and
               start_sec >= previous_end and start_sec >= 0 and seconds > 0 and
               start_sec + seconds <= duration ->
          {:cont,
           {:ok, [%{start_sec: start_sec, duration_sec: seconds} | acc], start_sec + seconds}}

        _rest, _acc ->
          {:halt, :error}
      end)
      |> case do
        {:ok, validated, _last_end} -> {:ok, Enum.reverse(validated)}
        :error -> :error
      end
    end
  end

  defp validate_rests(_rests, _duration, _recovery), do: :error
end
