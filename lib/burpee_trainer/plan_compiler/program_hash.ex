defmodule BurpeeTrainer.PlanCompiler.ProgramHash do
  @moduledoc "Canonical semantic encoding and content hash for execution programs."

  alias BurpeeTrainer.PlanCompiler.{Program, ProgramEvent}

  @spec canonical_map(Program.t()) :: map()
  def canonical_map(%Program{} = program) do
    %{
      schema_version: program.schema_version,
      solver_version: program.solver_version,
      burpee_type: Atom.to_string(program.burpee_type),
      target_reps: program.target_reps,
      target_duration_ms: sec_to_ms(program.target_duration_sec),
      events: Enum.map(program.events, &canonical_event/1),
      semantics: canonical_metadata(program.metadata)
    }
  end

  @spec encode!(Program.t()) :: String.t()
  def encode!(%Program{} = program) do
    program
    |> canonical_map()
    |> Jason.encode!()
  end

  @spec hash(Program.t()) :: String.t()
  def hash(%Program{} = program) do
    :crypto.hash(:sha256, encode!(program))
    |> Base.encode16(case: :lower)
  end

  defp canonical_event(%ProgramEvent.Work{} = event) do
    %{
      kind: "work",
      reps: event.reps,
      sec_per_rep_us: sec_to_us(event.sec_per_rep)
    }
  end

  defp canonical_event(%ProgramEvent.Rest{} = event) do
    %{
      kind: "rest",
      duration_ms: sec_to_ms(event.duration_sec)
    }
  end

  defp canonical_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.take([:pacing_style, :recovery_model, :policy_version])
    |> Enum.map(fn {key, value} -> {Atom.to_string(key), encode_source(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Map.new()
  end

  defp sec_to_ms(value), do: round(value * 1000)
  defp sec_to_us(value), do: round(value * 1_000_000)

  defp encode_source(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_source({left, right}), do: [encode_source(left), encode_source(right)]
  defp encode_source(value), do: value
end
