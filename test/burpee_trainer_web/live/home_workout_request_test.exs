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

  test "New's message is its choices, then a line for anything more, which is all that is sent" do
    params = %HomeWorkoutRequest{
      burpee_type: "six_count",
      pacing_style: "unbroken",
      reps: 75,
      duration: "20:00",
      pace: 4.5
    }

    assert HomeWorkoutRequest.summary(params) ==
             "Six-count · Unbroken · 20 min · 75 reps · 4.5 s per rep"

    message = HomeWorkoutRequest.message(params)

    assert message ==
             "Six-count · Unbroken · 20 min · 75 reps · 4.5 s per rep\nAdditional request: "

    assert HomeWorkoutRequest.note(message) == ""

    assert HomeWorkoutRequest.note(message <> "  a minute's break at 10:00 ") ==
             "a minute's break at 10:00"

    assert HomeWorkoutRequest.note("some\nadditional request: slow and steady") ==
             "slow and steady"

    # With the prefix deleted, what is left is still what the athlete wrote.
    assert HomeWorkoutRequest.note("  just make it gentle ") == "just make it gentle"

    assert HomeWorkoutRequest.summary(%{params | pace: nil}) =~ "coach picks the pace"
  end
end
