defmodule BurpeeTrainer.PlanCompiler.ProgramHash do
  @moduledoc "Canonical semantic encoding and content hash for execution programs."

  alias BurpeeTrainer.PlanCompiler.{Program, ProgramEvent}
  alias BurpeeTrainer.Workouts.Error

  @video_keys MapSet.new(["name", "filename", "type", "duration", "count", "format"])
  @legacy_metadata_keys [:pacing_style, :recovery_model, :policy_version]
  @source_v2_metadata_keys [
    :source_version,
    :source_hash,
    :pacing_style,
    :recovery_model,
    :policy_version,
    :policy_hash
  ]

  @spec canonical_map(Program.t()) :: map()
  def canonical_map(%Program{} = program) do
    %{
      "schema_version" => program.schema_version,
      "solver_version" => program.solver_version,
      "burpee_type" => Atom.to_string(program.burpee_type),
      "target_reps" => program.target_reps,
      "target_duration_ms" => sec_to_ms(program.target_duration_sec),
      "events" => Enum.map(program.events, &canonical_event/1),
      "semantics" => canonical_semantics(program)
    }
  end

  @spec encode!(Program.t()) :: String.t()
  def encode!(%Program{} = program) do
    program
    |> canonical_map()
    |> canonical_json()
  end

  @spec hash_canonical_map(map()) :: String.t()
  def hash_canonical_map(program_map) when is_map(program_map) do
    :crypto.hash(:sha256, canonical_json(program_map))
    |> Base.encode16(case: :lower)
  end

  @spec hash(Program.t()) :: String.t()
  def hash(%Program{} = program) do
    program
    |> canonical_map()
    |> hash_canonical_map()
  end

  @spec video_snapshot(map()) :: {:ok, map(), String.t()} | {:error, Error.t()}
  def video_snapshot(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_exact_video_map(attrs),
         :ok <- non_empty_string(:name, attrs["name"]),
         :ok <- non_empty_string(:filename, attrs["filename"]),
         {:ok, type} <- video_enum(:type, attrs["type"], [:six_count, :navy_seal]),
         :ok <- positive_integer(:duration, attrs["duration"]),
         :ok <- nullable_positive_integer(:count, attrs["count"]),
         {:ok, format} <- video_enum(:format, attrs["format"], [:follow_along]) do
      snapshot = %{
        "name" => attrs["name"],
        "filename" => attrs["filename"],
        "type" => type,
        "duration" => attrs["duration"],
        "count" => attrs["count"],
        "format" => format
      }

      {:ok, snapshot, hash_canonical_map(snapshot)}
    end
  end

  def video_snapshot(value), do: invalid_video(:snapshot, value)

  defp canonical_event(%ProgramEvent.Work{} = event) do
    %{
      "kind" => "work",
      "reps" => event.reps,
      "sec_per_rep_us" => sec_to_us(event.sec_per_rep),
      "sec_per_burpee_us" => sec_to_us(event.sec_per_burpee)
    }
    |> maybe_put_duration(event.duration_sec)
  end

  defp canonical_event(%ProgramEvent.Rest{} = event) do
    %{
      "kind" => "rest",
      "duration_ms" => sec_to_ms(event.duration_sec)
    }
  end

  defp maybe_put_duration(event, duration_sec) when is_number(duration_sec),
    do: Map.put(event, "duration_sec", duration_sec)

  defp maybe_put_duration(event, _duration_sec), do: event

  defp canonical_semantics(%Program{schema_version: 3, metadata: metadata}) do
    metadata = normalize_metadata(metadata)

    %{
      "definition_hash" => metadata[:definition_hash],
      "pacing_style" => encode_source(metadata[:pacing_style])
    }
  end

  defp canonical_semantics(%Program{metadata: metadata}), do: canonical_metadata(metadata)

  defp canonical_metadata(metadata) when is_map(metadata) do
    metadata = normalize_metadata(metadata)

    keys =
      if metadata[:source_version] == 2, do: @source_v2_metadata_keys, else: @legacy_metadata_keys

    metadata
    |> Map.take(keys)
    |> Enum.map(fn {key, value} -> {Atom.to_string(key), encode_source(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Map.new()
  end

  defp normalize_metadata(metadata) do
    Enum.reduce(metadata, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case normalize_metadata_key(key) do
          nil -> acc
          normalized_key -> Map.put(acc, normalized_key, value)
        end

      _entry, acc ->
        acc
    end)
  end

  defp normalize_metadata_key("definition_hash"), do: :definition_hash
  defp normalize_metadata_key("source_version"), do: :source_version
  defp normalize_metadata_key("source_hash"), do: :source_hash
  defp normalize_metadata_key("pacing_style"), do: :pacing_style
  defp normalize_metadata_key("recovery_model"), do: :recovery_model
  defp normalize_metadata_key("policy_version"), do: :policy_version
  defp normalize_metadata_key("policy_hash"), do: :policy_hash
  defp normalize_metadata_key(_key), do: nil

  defp normalize_exact_video_map(attrs) do
    with {:ok, normalized} <- normalize_video_keys(attrs),
         true <- MapSet.equal?(Map.keys(normalized) |> MapSet.new(), @video_keys) do
      {:ok, normalized}
    else
      false -> invalid_video(:snapshot, :unexpected_fields)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp normalize_video_keys(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn
      {key, value}, {:ok, normalized} when is_atom(key) or is_binary(key) ->
        key = to_string(key)

        if Map.has_key?(normalized, key) do
          {:halt, invalid_video(:snapshot, :duplicate_keys)}
        else
          {:cont, {:ok, Map.put(normalized, key, value)}}
        end

      {_key, _value}, _acc ->
        {:halt, invalid_video(:snapshot, :invalid_key)}
    end)
  end

  defp non_empty_string(_field, value) when is_binary(value) and byte_size(value) > 0 do
    if String.valid?(value), do: :ok, else: invalid_video(:string, :invalid_utf8)
  end

  defp non_empty_string(field, value), do: invalid_video(field, value)

  defp video_enum(field, value, allowed) do
    normalized = if is_atom(value), do: Atom.to_string(value), else: value
    allowed = Enum.map(allowed, &Atom.to_string/1)

    if normalized in allowed, do: {:ok, normalized}, else: invalid_video(field, value)
  end

  defp positive_integer(_field, value) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(field, value), do: invalid_video(field, value)

  defp nullable_positive_integer(_field, nil), do: :ok
  defp nullable_positive_integer(field, value), do: positive_integer(field, value)

  defp invalid_video(field, value) do
    {:error, Error.new(:invalid_video_snapshot, %{field: field, value: value})}
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

  defp sec_to_ms(value), do: round(value * 1000)
  defp sec_to_us(value), do: round(value * 1_000_000)

  defp encode_source(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_source({left, right}), do: [encode_source(left), encode_source(right)]
  defp encode_source(value), do: value
end
