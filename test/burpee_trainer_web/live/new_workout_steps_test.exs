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

  test "unbroken sets ask how large a set may be; an even beat does not" do
    unbroken = params(%{pacing_style: "unbroken"})
    assert NewWorkoutSteps.questions(unbroken) == [:type, :style, :duration, :reps, :sets, :pace]
    assert NewWorkoutSteps.questions(params()) == [:type, :style, :duration, :reps, :pace]

    assert NewWorkoutSteps.next(:reps, unbroken) == :sets
    assert NewWorkoutSteps.next(:reps, params()) == :pace
    assert NewWorkoutSteps.next(:pace, unbroken) == :ready
    assert NewWorkoutSteps.next(:ready, unbroken) == :request
    assert NewWorkoutSteps.previous(:pace, unbroken) == :sets
    assert NewWorkoutSteps.previous(:pace, params()) == :reps
    assert NewWorkoutSteps.previous(:type, params()) == :type
  end

  test "a set's size starts unlimited, tightens by five, and loosens back to unlimited" do
    p = params(%{pacing_style: "unbroken", reps: 60})

    assert NewWorkoutSteps.enter(%{p | max_set_reps: 20}, :sets, scope_fixture(), nil).max_set_reps ==
             nil

    assert NewWorkoutSteps.step(p, "sets", :down, nil).max_set_reps == 55
    assert NewWorkoutSteps.step(%{p | max_set_reps: 55}, "sets", :up, nil).max_set_reps == nil
    assert NewWorkoutSteps.step(%{p | max_set_reps: 5}, "sets", :down, nil).max_set_reps == 5
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
