defmodule BurpeeTrainerWeb.HomeWorkoutRequestTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainerWeb.HomeWorkoutRequest
  alias BurpeeTrainer.Coach.WorkoutRequest

  test "selected fields override extraction while additional constraints survive" do
    {:ok, extracted} =
      WorkoutRequest.new(%{
        "burpee_type" => "navy_seal",
        "target_reps" => 8,
        "target_duration_sec" => 1200,
        "pacing_style" => "even",
        "recovery" => "required",
        "timed_rests" => [%{"start_sec" => 660, "duration_sec" => 60}],
        "requested_pace_sec" => 5
      })

    {:ok, params} =
      %HomeWorkoutRequest{}
      |> HomeWorkoutRequest.changeset(%{"reps" => "140", "duration" => "20:00"})
      |> Ecto.Changeset.apply_action(:insert)

    assert {:ok, request} = HomeWorkoutRequest.request(params, extracted)
    assert request.target_reps == 140
    assert request.burpee_type == "six_count"
    assert request.pacing_style == "unbroken"
    assert request.timed_rests == [%{start_sec: 660, duration_sec: 60}]
  end

  test "form derives its local budget and ordered sets before rest entry" do
    changeset =
      HomeWorkoutRequest.changeset(%HomeWorkoutRequest{}, %{
        "reps" => "140",
        "pace" => "5",
        "sets" => "5x8,5x7,5x(7,6)",
        "rests" => "60s at 11:00"
      })

    assert {:ok, params} = Ecto.Changeset.apply_action(changeset, :insert)

    assert {:ok, %{work_us: 700_000_000, recovery_us: 500_000_000}} =
             HomeWorkoutRequest.budget(params)

    assert {:ok, request} = HomeWorkoutRequest.request(params)
    assert length(request.set_reps) == 20
    assert request.timed_rests == [%{start_sec: 660, duration_sec: 60}]
    refute HomeWorkoutRequest.changeset(params, %{"reps" => "150"}).valid?
    refute HomeWorkoutRequest.changeset(params, %{"pace" => "10"}).valid?
  end

  test "invalid duration and reps fail before provider calls" do
    changeset =
      HomeWorkoutRequest.changeset(%HomeWorkoutRequest{}, %{"reps" => "0", "duration" => "0:00"})

    refute changeset.valid?
  end
end
