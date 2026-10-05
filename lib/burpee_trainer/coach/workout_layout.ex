defmodule BurpeeTrainer.Coach.WorkoutLayout do
  @moduledoc "Strict JSON schema for the LLM's workout layout, without rest durations."

  alias BurpeeTrainer.Coach.WorkoutRequest

  @spec json_schema(WorkoutRequest.t()) :: map()
  def json_schema(%WorkoutRequest{} = request) do
    phase_count = length(request.timed_rests) + 1

    set = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["reps", "sec_per_rep", "sec_per_burpee"],
      "properties" => %{
        "reps" => %{"type" => "integer", "minimum" => 1},
        "sec_per_rep" => %{
          "type" => "number",
          "description" => "Start-to-start seconds per rep, at most three decimals."
        },
        "sec_per_burpee" => %{
          "type" => "number",
          "description" =>
            "Active seconds per rep, at most three decimals and no greater than sec_per_rep."
        }
      }
    }

    phase = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["sets", "rest_weights"],
      "properties" => %{
        "sets" => %{"type" => "array", "minItems" => 1, "items" => set},
        "rest_weights" => %{
          "type" => "array",
          "description" =>
            "One positive relative weight per gap between sets; equal weights mean even rests.",
          "items" => %{"type" => "number", "exclusiveMinimum" => 0}
        }
      }
    }

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["name", "rationale", "phases"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "rationale" => %{"type" => "string"},
        "phases" => %{
          "type" => "array",
          "minItems" => phase_count,
          "maxItems" => phase_count,
          "description" =>
            "Each non-terminal phase ends where its fixed pause begins; the terminal phase ends the workout.",
          "items" => phase
        }
      }
    }
  end
end
