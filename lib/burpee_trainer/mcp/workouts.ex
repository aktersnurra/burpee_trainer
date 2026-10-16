defmodule BurpeeTrainer.Mcp.Workouts do
  @moduledoc """
  Workouts as Claude reads and writes them. Claude writes the authoring form documented in
  `burpee://workout-format` (what the workout asks for, and phases of sets with rest
  weights); the app fits the rests, checks and compiles it exactly as it does for its own
  coach, and stores the exact definition. Reading a workout gives the exact definition and
  an `editable` authoring form whose rest weights are the stored rests, so sending it back
  unchanged stores an equal workout.
  """

  alias BurpeeTrainer.Coach.{Rationale, RestFitter, Voice, WorkoutRequest}
  alias BurpeeTrainer.PlanCompiler
  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition

  @request_keys ~w[burpee_type target_reps target_duration_sec pacing_style recovery timed_rests requested_pace_sec set_reps]
  @layout_keys ~w[name rationale phases]

  def keys, do: @request_keys ++ @layout_keys

  @doc "The authoring form's JSON schema, from `WorkoutRequest` and the layout's fields."
  def schema do
    request = WorkoutRequest.json_schema()

    set = %{
      "type" => "object",
      "properties" => %{
        "reps" => %{"type" => "integer", "minimum" => 1},
        "sec_per_rep" => %{"type" => "number", "description" => "Start-to-start seconds per rep."},
        "sec_per_burpee" => %{
          "type" => "number",
          "description" => "Seconds of movement per rep, at most sec_per_rep."
        }
      },
      "required" => ~w[reps sec_per_rep sec_per_burpee],
      "additionalProperties" => false
    }

    phase = %{
      "type" => "object",
      "properties" => %{
        "sets" => %{"type" => "array", "minItems" => 1, "items" => set},
        "rest_weights" => %{
          "type" => "array",
          "items" => %{"type" => "number", "exclusiveMinimum" => 0},
          "description" =>
            "One weight per gap between the phase's sets; the app shares the phase's spare time between them by weight."
        }
      },
      "required" => ~w[sets rest_weights],
      "additionalProperties" => false
    }

    request.properties
    |> Map.new(fn {key, value} -> {to_string(key), Jason.decode!(Jason.encode!(value))} end)
    |> Map.merge(%{
      "name" => %{
        "type" => "string",
        "description" => "Two to four plain words, not its reps, minutes or level."
      },
      "rationale" => %{
        "type" => "string",
        "maxLength" => Rationale.max_length(),
        "description" => "One plain sentence on why this workout, shown under it."
      },
      "phases" => %{
        "type" => "array",
        "minItems" => 1,
        "items" => phase,
        "description" => "One more phase than timed_rests."
      }
    })
  end

  def required,
    do:
      ~w[name rationale burpee_type target_reps target_duration_sec pacing_style recovery timed_rests phases]

  @doc "Checks Claude's authoring form and returns the exact definition the app would store."
  @spec definition(map()) :: {:ok, map()} | {:error, String.t()}
  def definition(args) do
    with [] <- Map.keys(args) -- keys(),
         [] <- required() -- Map.keys(args),
         :ok <- plain_name(args["name"]),
         {:ok, rationale} <- Rationale.validate(args["rationale"]),
         {:ok, request} <- request(args),
         {:ok, canonical} <-
           fit(request, %{
             "name" => args["name"],
             "rationale" => rationale,
             "phases" => args["phases"]
           }),
         {:ok, definition} <- WorkoutDefinition.new(canonical),
         {:ok, _program} <- PlanCompiler.compile(definition),
         :ok <- WorkoutRequest.validate_definition(request, definition) do
      {:ok, WorkoutDefinition.canonical_map(definition)}
    else
      [_ | _] = keys ->
        if Enum.all?(keys, &(&1 in required())),
          do: {:error, "missing: #{Enum.join(keys, ", ")}"},
          else: {:error, "unknown fields: #{Enum.join(keys, ", ")}"}

      {:error, %{code: code, context: context}} ->
        {:error, "#{code}: #{inspect(context)}"}

      {:error, _error, detail} ->
        {:error, detail}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  defp request(args) do
    args
    |> Map.take(@request_keys)
    |> Map.put_new("requested_pace_sec", nil)
    |> WorkoutRequest.new()
  end

  defp fit(request, layout) do
    case RestFitter.fit(request, layout) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, reason} -> {:error, RestFitter.describe(reason)}
    end
  end

  defp plain_name(name) when is_binary(name) do
    case Voice.internal_id(name) do
      nil -> :ok
      id -> {:error, "the name is shown to the athlete; write #{id} in plain words"}
    end
  end

  defp plain_name(_name), do: {:error, "name must be a string"}

  @doc "A stored plan as Claude reads it."
  def encode(plan) do
    definition = plan.definition_json

    %{
      "id" => plan.id,
      "name" => plan.name,
      "state" => to_string(plan.state),
      "built_in" => plan.origin == :built_in,
      "burpee_type" => to_string(plan.burpee_type),
      "target_reps" => plan.target_reps,
      "target_duration_sec" => plan.target_duration_sec,
      "pacing_style" => definition["pacing_style"],
      "rationale" => definition["rationale"],
      "summary" => summary(definition),
      "definition" => definition,
      "editable" => editable(definition)
    }
  end

  @doc "A plan's line in the library."
  def entry(plan) do
    work = Enum.filter(plan.definition_json["events"], &(&1["kind"] == "work"))

    %{
      "id" => plan.id,
      "name" => plan.name,
      "built_in" => plan.origin == :built_in,
      "burpee_type" => to_string(plan.burpee_type),
      "target_reps" => plan.target_reps,
      "target_duration_sec" => plan.target_duration_sec,
      "pacing_style" => plan.definition_json["pacing_style"],
      "sec_per_burpee" => work |> Enum.map(& &1["sec_per_burpee"]) |> Enum.uniq() |> one(),
      "summary" => summary(plan.definition_json)
    }
  end

  defp one([value]), do: value
  defp one(_values), do: nil

  @doc "One plain line: sets, cadence, movement, rests and length."
  def summary(definition) do
    events = definition["events"]
    works = Enum.filter(events, &(&1["kind"] == "work"))
    rests = events |> Enum.filter(&(&1["kind"] == "rest")) |> Enum.map(& &1["duration_sec"])

    sets =
      case works |> Enum.map(& &1["reps"]) |> Enum.uniq() do
        [reps] -> "#{length(works)} #{plural(length(works), "set")} of #{reps}"
        _ -> "sets of " <> Enum.map_join(works, ", ", & &1["reps"])
      end

    cadence =
      case works |> Enum.map(&{&1["sec_per_rep"], &1["sec_per_burpee"]}) |> Enum.uniq() do
        [{rep, burpee}] -> "#{number(rep)} s per rep (#{number(burpee)} s moving)"
        _ -> "varying pace"
      end

    rest =
      case Enum.uniq(rests) do
        [] -> "no rests"
        [one] -> "#{number(one)} s between sets"
        many -> "#{number(Enum.min(many))}–#{number(Enum.max(many))} s rests"
      end

    "#{sets}, #{cadence}, #{rest}, #{number(definition["target_duration_sec"] / 60)} min"
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp number(value) when is_integer(value), do: Integer.to_string(value)

  defp number(value) when is_float(value) do
    if value == Float.round(value),
      do: value |> round() |> Integer.to_string(),
      else: :erlang.float_to_binary(value, decimals: 1)
  end

  @doc """
  The authoring form of a stored definition: one phase, its sets in order, and the stored
  rests as weights. Nil when the definition does not alternate sets and rests (a rest
  first or last), which the authoring form cannot say.
  """
  def editable(definition) do
    events = merge_rests(definition["events"])

    with %{"kind" => "work"} <- List.first(events),
         %{"kind" => "work"} <- List.last(events),
         {sets, weights} <- alternate(events, [], []) do
      %{
        "name" => definition["name"],
        "rationale" => definition["rationale"],
        "burpee_type" => definition["burpee_type"],
        "target_reps" => definition["target_reps"],
        "target_duration_sec" => definition["target_duration_sec"],
        "pacing_style" => definition["pacing_style"],
        "recovery" => "optional",
        "timed_rests" => [],
        "requested_pace_sec" => nil,
        "phases" => [%{"sets" => sets, "rest_weights" => weights}]
      }
    else
      _ -> nil
    end
  end

  defp merge_rests(events) do
    events
    |> Enum.chunk_by(& &1["kind"])
    |> Enum.flat_map(fn
      [%{"kind" => "rest"} | _] = rests ->
        [
          %{
            "kind" => "rest",
            "duration_sec" => rests |> Enum.map(& &1["duration_sec"]) |> Enum.sum()
          }
        ]

      works ->
        works
    end)
  end

  defp alternate([], sets, weights), do: {Enum.reverse(sets), Enum.reverse(weights)}

  defp alternate([%{"kind" => "work"} = work | rest], sets, weights) do
    set = Map.take(work, ~w[reps sec_per_rep sec_per_burpee])

    case rest do
      [] ->
        alternate([], [set | sets], weights)

      [%{"kind" => "rest", "duration_sec" => d} | more] ->
        alternate(more, [set | sets], [d | weights])

      _ ->
        :error
    end
  end

  defp alternate(_events, _sets, _weights), do: :error
end
