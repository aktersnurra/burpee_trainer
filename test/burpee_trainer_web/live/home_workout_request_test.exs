defmodule BurpeeTrainerWeb.HomeWorkoutRequestTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainerWeb.HomeWorkoutRequest

  test "the fields make the request; sets and pauses come only from the note, via the coach" do
    changeset =
      HomeWorkoutRequest.changeset(%HomeWorkoutRequest{}, %{
        "reps" => "140",
        "pace" => "5",
        "note" => "Two sets of 70, a minute's break at 11:00",
        "sets" => "5x8,5x7,5x(7,6)",
        "rests" => "60s at 11:00"
      })

    assert {:ok, params} = Ecto.Changeset.apply_action(changeset, :insert)
    refute Map.has_key?(params, :sets)
    refute Map.has_key?(params, :rests)

    assert {:ok, %{work_us: 700_000_000, recovery_us: 500_000_000}} =
             HomeWorkoutRequest.budget(params)

    assert {:ok, request} = HomeWorkoutRequest.request(params)
    assert request.target_reps == 140
    assert request.set_reps == []
    assert request.timed_rests == []
    assert HomeWorkoutRequest.instruction(params) =~ "Two sets of 70"
    refute HomeWorkoutRequest.changeset(params, %{"pace" => "10"}).valid?
  end

  test "invalid duration and reps fail before provider calls" do
    changeset =
      HomeWorkoutRequest.changeset(%HomeWorkoutRequest{}, %{"reps" => "0", "duration" => "0:00"})

    refute changeset.valid?
  end
end
