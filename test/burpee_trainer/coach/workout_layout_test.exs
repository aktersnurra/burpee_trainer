defmodule BurpeeTrainer.Coach.WorkoutLayoutTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Coach.{WorkoutLayout, WorkoutRequest}

  test "schema fixes phase count to timed rests plus one and excludes timeline events" do
    {:ok, request} =
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => 140,
        "target_duration_sec" => 1200,
        "pacing_style" => "unbroken",
        "recovery" => "required",
        "requested_pace_sec" => 5.0,
        "timed_rests" => [
          %{"start_sec" => 660, "duration_sec" => 60},
          %{"start_sec" => 1080, "duration_sec" => 40}
        ]
      })

    schema = WorkoutLayout.json_schema(request)
    assert schema["properties"]["phases"]["minItems"] == 3
    assert schema["properties"]["phases"]["maxItems"] == 3
    assert schema["required"] == ["name", "rationale", "phases"]
    refute Map.has_key?(schema["properties"], "events")
  end
end
