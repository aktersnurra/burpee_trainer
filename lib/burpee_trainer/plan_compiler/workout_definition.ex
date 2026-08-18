defmodule BurpeeTrainer.PlanCompiler.WorkoutDefinition do
  @moduledoc "Canonical, validated workout definition."

  alias BurpeeTrainer.Workouts.Error

  @version 1
  @max_definition_bytes 16_384
  @max_events 10_000
  @max_duration_sec 86_400
  @max_target_reps 100_000
  @definition_fields [
    "version",
    "name",
    "burpee_type",
    "target_duration_sec",
    "target_reps",
    "pacing_style",
    "rationale",
    "events"
  ]
  @definition_keys MapSet.new(@definition_fields)
  @work_keys MapSet.new(["kind", "reps", "sec_per_rep", "sec_per_burpee"])
  @rest_keys MapSet.new(["kind", "duration_sec"])

  @enforce_keys [
    :version,
    :name,
    :burpee_type,
    :target_duration_sec,
    :target_reps,
    :pacing_style,
    :rationale,
    :events
  ]
  defstruct @enforce_keys

  @type event ::
          %{
            kind: :work,
            reps: pos_integer(),
            sec_per_rep: float(),
            sec_per_burpee: float()
          }
          | %{kind: :rest, duration_sec: float()}

  @type t :: %__MODULE__{
          version: 1,
          name: String.t(),
          burpee_type: :six_count | :navy_seal,
          target_duration_sec: pos_integer(),
          target_reps: pos_integer(),
          pacing_style: :even | :unbroken,
          rationale: String.t(),
          events: [event(), ...]
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_exact_map(attrs, @definition_keys, :definition),
         :ok <- validate_encoded_size(attrs),
         :ok <- exact_version(attrs["version"]),
         {:ok, name} <- non_empty_string(:name, attrs["name"]),
         {:ok, burpee_type} <- enum(:burpee_type, attrs["burpee_type"], [:six_count, :navy_seal]),
         :ok <- positive_integer(:target_duration_sec, attrs["target_duration_sec"]),
         :ok <- maximum(:target_duration_sec, attrs["target_duration_sec"], @max_duration_sec),
         :ok <- positive_integer(:target_reps, attrs["target_reps"]),
         :ok <- maximum(:target_reps, attrs["target_reps"], @max_target_reps),
         {:ok, pacing_style} <- enum(:pacing_style, attrs["pacing_style"], [:even, :unbroken]),
         {:ok, rationale} <- non_empty_string(:rationale, attrs["rationale"]),
         {:ok, events} <- events(attrs["events"]),
         :ok <- validate_rep_total(events, attrs["target_reps"]),
         :ok <- validate_duration(events, attrs["target_duration_sec"]) do
      {:ok,
       %__MODULE__{
         version: @version,
         name: name,
         burpee_type: burpee_type,
         target_duration_sec: attrs["target_duration_sec"],
         target_reps: attrs["target_reps"],
         pacing_style: pacing_style,
         rationale: rationale,
         events: events
       }}
    end
  end

  def new(value), do: invalid(:definition, value)

  @spec json_schema() :: map()
  def json_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => @definition_fields,
      "properties" => %{
        "version" => %{"type" => "integer", "enum" => [@version]},
        "name" => %{"type" => "string"},
        "burpee_type" => %{"type" => "string", "enum" => ["six_count", "navy_seal"]},
        "target_duration_sec" => %{
          "type" => "integer",
          "description" => "Exact total duration in seconds across every event."
        },
        "target_reps" => %{
          "type" => "integer",
          "description" => "Exact sum of reps across all work events."
        },
        "pacing_style" => %{"type" => "string", "enum" => ["even", "unbroken"]},
        "rationale" => %{"type" => "string"},
        "events" => %{
          "type" => "array",
          "minItems" => 1,
          "description" =>
            "Ordered workout timeline. Non-terminal work duration is reps * sec_per_rep. " <>
              "Terminal work duration is (reps - 1) * sec_per_rep + sec_per_burpee. " <>
              "Rest duration is duration_sec.",
          "items" => %{
            "anyOf" => [work_event_json_schema(), rest_event_json_schema()]
          }
        }
      }
    }
  end

  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = definition) do
    %{
      "version" => definition.version,
      "name" => definition.name,
      "burpee_type" => Atom.to_string(definition.burpee_type),
      "target_duration_sec" => definition.target_duration_sec,
      "target_reps" => definition.target_reps,
      "pacing_style" => Atom.to_string(definition.pacing_style),
      "rationale" => definition.rationale,
      "events" => Enum.map(definition.events, &canonical_event/1)
    }
  end

  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{} = definition) do
    definition
    |> canonical_map()
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp work_event_json_schema do
    %{
      "type" => "object",
      "description" =>
        "A work interval. Only work events contribute repetitions; all requested repetitions " <>
          "must be represented by the sum of work-event reps.",
      "additionalProperties" => false,
      "required" => ["kind", "reps", "sec_per_rep", "sec_per_burpee"],
      "properties" => %{
        "kind" => %{"type" => "string", "enum" => ["work"]},
        "reps" => %{"type" => "integer"},
        "sec_per_rep" => %{
          "type" => "number",
          "description" => "Start-to-start cadence in seconds."
        },
        "sec_per_burpee" => %{
          "type" => "number",
          "description" => "Active duration of one burpee; must not exceed sec_per_rep."
        }
      }
    }
  end

  defp rest_event_json_schema do
    %{
      "type" => "object",
      "description" =>
        "A rest interval. Rest events contribute zero repetitions and must never replace work.",
      "additionalProperties" => false,
      "required" => ["kind", "duration_sec"],
      "properties" => %{
        "kind" => %{"type" => "string", "enum" => ["rest"]},
        "duration_sec" => %{"type" => "number"}
      }
    }
  end

  defp events(values) when is_list(values) and values != [] do
    if Enum.count(Enum.take(values, @max_events + 1)) > @max_events do
      invalid(:events, :too_many_events)
    else
      values
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, events} ->
        case event(value, index) do
          {:ok, event} -> {:cont, {:ok, [event | events]}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end)
      |> then(fn
        {:ok, events} -> {:ok, Enum.reverse(events)}
        error -> error
      end)
    end
  end

  defp events(value), do: invalid(:events, value)

  defp event(value, index) when is_map(value) do
    case normalized_kind(value) do
      {:ok, "work"} -> work_event(value, index)
      {:ok, "rest"} -> rest_event(value, index)
      _error -> invalid({:event, index, :kind}, map_value(value, :kind))
    end
  end

  defp event(value, index), do: invalid({:event, index}, value)

  defp work_event(value, index) do
    with {:ok, value} <- normalize_exact_map(value, @work_keys, {:event, index}),
         :ok <- positive_integer({:event, index, :reps}, value["reps"]),
         :ok <- maximum({:event, index, :reps}, value["reps"], @max_target_reps),
         :ok <- positive_number({:event, index, :sec_per_rep}, value["sec_per_rep"]),
         :ok <- positive_microseconds({:event, index, :sec_per_rep}, value["sec_per_rep"]),
         :ok <- positive_number({:event, index, :sec_per_burpee}, value["sec_per_burpee"]),
         :ok <-
           positive_microseconds(
             {:event, index, :sec_per_burpee},
             value["sec_per_burpee"]
           ),
         :ok <- feasible_work(value, index) do
      {:ok,
       %{
         kind: :work,
         reps: value["reps"],
         sec_per_rep: value["sec_per_rep"] * 1.0,
         sec_per_burpee: value["sec_per_burpee"] * 1.0
       }}
    end
  end

  defp rest_event(value, index) do
    with {:ok, value} <- normalize_exact_map(value, @rest_keys, {:event, index}),
         :ok <- positive_number({:event, index, :duration_sec}, value["duration_sec"]),
         :ok <- positive_milliseconds({:event, index, :duration_sec}, value["duration_sec"]),
         :ok <- maximum({:event, index, :duration_sec}, value["duration_sec"], @max_duration_sec) do
      {:ok, %{kind: :rest, duration_sec: value["duration_sec"] * 1.0}}
    end
  end

  defp validate_rep_total(events, target_reps) do
    actual =
      Enum.reduce(events, 0, fn
        %{kind: :work, reps: reps}, total -> total + reps
        %{kind: :rest}, total -> total
      end)

    if actual == target_reps do
      :ok
    else
      invalid(:target_reps, %{actual: actual, expected: target_reps})
    end
  end

  defp validate_duration(events, target_duration_sec) do
    terminal_index = length(events) - 1

    actual_us =
      events
      |> Enum.with_index()
      |> Enum.reduce(0, fn
        {%{kind: :work, reps: reps, sec_per_rep: cadence, sec_per_burpee: active},
         ^terminal_index},
        total ->
          total + (reps - 1) * sec_to_us(cadence) + sec_to_us(active)

        {%{kind: :work, reps: reps, sec_per_rep: cadence}, _index}, total ->
          total + reps * sec_to_us(cadence)

        {%{kind: :rest, duration_sec: duration_sec}, _index}, total ->
          total + sec_to_ms(duration_sec) * 1_000
      end)

    expected_us = target_duration_sec * 1_000_000

    if actual_us == expected_us do
      :ok
    else
      invalid(:target_duration_sec, %{actual_us: actual_us, expected_us: expected_us})
    end
  end

  defp validate_encoded_size(attrs) do
    case Jason.encode(attrs) do
      {:ok, encoded} when byte_size(encoded) <= @max_definition_bytes -> :ok
      {:ok, _encoded} -> invalid(:definition, :too_many_bytes)
      {:error, _reason} -> invalid(:definition, :invalid_json_shape)
    end
  end

  defp normalize_exact_map(value, keys, field) do
    with {:ok, normalized} <- normalize_keys(value, field),
         true <- MapSet.equal?(Map.keys(normalized) |> MapSet.new(), keys) do
      {:ok, normalized}
    else
      false -> invalid(field, :unexpected_fields)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp normalize_keys(value, field) do
    Enum.reduce_while(value, {:ok, %{}}, fn
      {key, nested}, {:ok, normalized} when is_atom(key) or is_binary(key) ->
        key = to_string(key)

        if Map.has_key?(normalized, key) do
          {:halt, invalid(field, :duplicate_keys)}
        else
          {:cont, {:ok, Map.put(normalized, key, nested)}}
        end

      {_key, _nested}, _acc ->
        {:halt, invalid(field, :invalid_key)}
    end)
  end

  defp normalized_kind(value) do
    case normalize_keys(value, :event) do
      {:ok, normalized} -> {:ok, normalized["kind"]}
      error -> error
    end
  end

  defp map_value(value, key), do: Map.get(value, key, Map.get(value, to_string(key)))

  defp exact_version(@version), do: :ok
  defp exact_version(value), do: invalid(:version, value)

  defp enum(field, value, allowed) do
    normalized =
      if is_binary(value), do: Enum.find(allowed, &(Atom.to_string(&1) == value)), else: value

    if normalized in allowed, do: {:ok, normalized}, else: invalid(field, value)
  end

  defp non_empty_string(_field, value) when is_binary(value) and byte_size(value) > 0 do
    if String.valid?(value), do: {:ok, value}, else: invalid(:string, :invalid_utf8)
  end

  defp non_empty_string(field, value), do: invalid(field, value)

  defp positive_integer(_field, value) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(field, value), do: invalid(field, value)

  defp positive_number(_field, value) when is_number(value) and value > 0, do: :ok
  defp positive_number(field, value), do: invalid(field, value)

  defp positive_microseconds(_field, value) when round(value * 1_000_000) > 0, do: :ok
  defp positive_microseconds(field, value), do: invalid(field, value)

  defp positive_milliseconds(_field, value) when round(value * 1_000) > 0, do: :ok
  defp positive_milliseconds(field, value), do: invalid(field, value)

  defp maximum(_field, value, max) when value <= max, do: :ok
  defp maximum(field, value, _max), do: invalid(field, value)

  defp feasible_work(
         %{"sec_per_burpee" => active, "sec_per_rep" => cadence},
         _index
       )
       when active <= cadence,
       do: :ok

  defp feasible_work(value, index) do
    invalid({:event, index}, %{
      sec_per_burpee: value["sec_per_burpee"],
      sec_per_rep: value["sec_per_rep"]
    })
  end

  defp canonical_event(%{kind: :work} = event) do
    %{
      "kind" => "work",
      "reps" => event.reps,
      "sec_per_rep" => event.sec_per_rep,
      "sec_per_burpee" => event.sec_per_burpee
    }
  end

  defp canonical_event(%{kind: :rest} = event) do
    %{"kind" => "rest", "duration_sec" => event.duration_sec}
  end

  defp canonical_json(value) when is_map(value) do
    body =
      value
      |> Enum.map(fn {key, nested_value} -> {to_string(key), nested_value} end)
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, nested_value} ->
        Jason.encode!(key) <> ":" <> canonical_json(nested_value)
      end)

    "{" <> body <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp sec_to_ms(value), do: round(value * 1_000)
  defp sec_to_us(value), do: round(value * 1_000_000)

  defp invalid(field, value) do
    {:error, Error.new(:invalid_workout_definition, %{field: field, value: value})}
  end
end
