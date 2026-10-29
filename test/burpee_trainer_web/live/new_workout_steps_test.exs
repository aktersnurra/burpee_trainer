defmodule BurpeeTrainerWeb.NewWorkoutStepsTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainerWeb.{HomeWorkoutRequest, NewWorkoutSteps}

  defp params(attrs \\ %{}),
    do:
      struct!(
        HomeWorkoutRequest,
        Map.merge(
          %{
            burpee_type: "six_count",
            pacing_style: "even",
            reps: 120,
            duration: "20:00",
            pace: nil
          },
          attrs
        )
      )

  test "the questions run in order and end at the message" do
    assert NewWorkoutSteps.steps() == [:type, :style, :duration, :reps, :pace, :ready]
    assert NewWorkoutSteps.next(:duration) == :reps
    assert NewWorkoutSteps.next(:pace) == :ready
    assert NewWorkoutSteps.next(:ready) == :ready
  end

  test "only an answerable step can be gone back to" do
    assert NewWorkoutSteps.parse("duration") == {:ok, :duration}
    assert NewWorkoutSteps.parse("ready") == :error
    assert NewWorkoutSteps.parse("nope") == :error
    assert NewWorkoutSteps.parse(nil) == :error
  end

  test "duration starts at twenty minutes, or at what the week has left" do
    scope = scope_fixture()
    assert NewWorkoutSteps.enter(params(), :duration, scope, 4_800).duration == "20:00"
    assert NewWorkoutSteps.enter(params(), :duration, scope, 600).duration == "10:00"
  end

  test "duration never moves past the week's time left" do
    p = params(%{duration: "35:00"})
    assert NewWorkoutSteps.step(p, "duration", :up, 2_400).duration == "40:00"

    assert NewWorkoutSteps.step(params(%{duration: "40:00"}), "duration", :up, 2_400).duration ==
             "40:00"

    assert NewWorkoutSteps.step(params(%{duration: "5:00"}), "duration", :down, 2_400).duration ==
             "5:00"
  end

  test "reps start from the suggestion with a pace that fits, and stop where movement would not" do
    scope = scope_fixture()
    p = NewWorkoutSteps.enter(params(%{duration: "5:00"}), :reps, scope, nil)
    assert p.reps == 15
    assert p.pace == 4.5

    # 300 s at 4.5 s holds 66 reps.
    assert NewWorkoutSteps.step(%{p | reps: 65}, "reps", :up, nil).reps == 65
    assert NewWorkoutSteps.step(%{p | reps: 60}, "reps", :up, nil).reps == 65
    assert NewWorkoutSteps.step(%{p | reps: 5}, "reps", :down, nil).reps == 5
  end

  test "pace moves by half a second, and never so slow that the reps no longer fit" do
    p = params(%{duration: "5:00", reps: 60, pace: 4.5})
    assert NewWorkoutSteps.step(p, "pace", :up, nil).pace == 5.0
    assert NewWorkoutSteps.step(%{p | reps: 66, pace: 4.5}, "pace", :up, nil).pace == 4.5
    assert NewWorkoutSteps.step(p, "pace", :down, nil).pace == 4.0
  end
end
