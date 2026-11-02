defmodule BurpeeTrainer.Coach.WorkoutLayout do
  @moduledoc "Strict JSON schema for a workout layout: sets, and each rest exact or a share."

  alias BurpeeTrainer.Coach.WorkoutRequest

  @max_suggestions 3
  @max_suggestion_length 60

  @doc """
  The asks the coach offers under its proposal, from a layout: short, distinct, at most three.
  A layout without them, or with ones that are not short text, offers none.
  """
  @spec suggestions(map()) :: [String.t()]
  def suggestions(%{"suggestions" => list}) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != "" and String.length(&1) <= @max_suggestion_length))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(@max_suggestions)
  end

  def suggestions(_layout), do: []

  @doc """
  One rest between two sets: `{"sec": n}` is exactly n seconds after the last rep's beat (0
  starts the next set on the next beat); `{"share": w}` takes a share, by weight, of the
  phase's time left after its sets, cadence tails and exact rests.
  """
  @spec rest_schema() :: map()
  def rest_schema do
    %{
      "anyOf" => [
        %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["sec"],
          "properties" => %{
            "sec" => %{
              "type" => "number",
              "minimum" => 0,
              "description" =>
                "Exactly this many seconds of rest after the last rep's beat; 0 starts the next set on the next beat."
            }
          }
        },
        %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["share"],
          "properties" => %{
            "share" => %{
              "type" => "number",
              "exclusiveMinimum" => 0,
              "description" =>
                "A share, by weight, of the phase's time left after its sets, cadence tails and exact rests."
            }
          }
        }
      ]
    }
  end

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
      "required" => ["sets", "rests"],
      "properties" => %{
        "sets" => %{"type" => "array", "minItems" => 1, "items" => set},
        "rests" => %{
          "type" => "array",
          "description" =>
            "One rest per gap between sets, in order. Use share unless the athlete gave the rest's length.",
          "items" => rest_schema()
        }
      }
    }

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["name", "rationale", "phases", "suggestions"],
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" =>
            "The workout's title for the athlete: two to four plain words, not its reps, minutes or level, which are shown beside it."
        },
        "rationale" => %{
          "type" => "string",
          "description" => BurpeeTrainer.Coach.Rationale.description()
        },
        "suggestions" => %{
          "type" => "array",
          "maxItems" => @max_suggestions,
          "description" =>
            "Up to three changes the athlete is most likely to ask for next about this workout, as they would type them: short imperatives of at most #{@max_suggestion_length} characters, each one the coach can make, and specific to this layout (name the set or the time). For example \"Even out the rests\", \"Add a 1-minute rest at 10:00\", \"Front-load the reps\". Not a change this layout already makes.",
          "items" => %{"type" => "string"}
        },
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
