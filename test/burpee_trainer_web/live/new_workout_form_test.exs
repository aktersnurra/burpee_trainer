defmodule BurpeeTrainerWeb.NewWorkoutFormTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainerWeb.{HomeWorkoutRequest, NewWorkoutForm}

  setup do
    %{scope: scope_fixture()}
  end

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

  defp change(form, field, value, scope, remaining \\ nil),
    do: NewWorkoutForm.change(form, field, value, scope, remaining)

  defp step(form, field, dir, scope, remaining \\ nil),
    do: NewWorkoutForm.step(form, field, dir, scope, remaining)

  test "opens on twenty minutes, or the week's time left, with reps and a pace that fit", %{
    scope: scope
  } do
    form = NewWorkoutForm.open(params(), scope, 4_800)
    assert form.params.duration == "20:00"
    # With no history, the next level's landmark scaled to the duration.
    assert form.params.reps == 50
    assert form.params.pace == 4.5
    assert form.touched == MapSet.new()

    assert NewWorkoutForm.open(params(), scope, 600).params.duration == "10:00"
  end

  test "reps and pace follow the duration and type until they are set by hand", %{scope: scope} do
    form = NewWorkoutForm.open(params(), scope, nil)

    shorter = change(form, "duration", "5", scope)
    assert shorter.params.duration == "5:00"
    assert shorter.params.reps == 15

    seal = change(form, "burpee_type", "navy_seal", scope)
    assert seal.params.pace == 8.0

    set = change(form, "reps", "40", scope)
    assert set.params.reps == 40
    assert change(set, "duration", "25", scope).params.reps == 40
  end

  test "a value set by hand gives way only when it no longer fits", %{scope: scope} do
    form =
      NewWorkoutForm.open(params(), scope, nil)
      |> change("reps", "100", scope)
      |> change("pace", "6", scope)

    # 100 reps at 6 s is 10 minutes of movement; 5 minutes hold 50.
    assert change(form, "duration", "5", scope).params.reps == 50
    assert change(form, "duration", "15", scope).params.reps == 100
  end

  test "the value being changed is capped at what the others leave room for", %{scope: scope} do
    form =
      NewWorkoutForm.open(params(), scope, nil)
      |> change("duration", "5", scope)
      |> change("pace", "5", scope)

    # 300 s at 5 s holds 60 reps.
    assert change(form, "reps", "500", scope).params.reps == 60

    form = change(form, "reps", "50", scope)
    assert change(form, "pace", "9", scope).params.pace == 6.0
  end

  test "reps stop where movement at the pace would fill the duration", %{scope: scope} do
    form = NewWorkoutForm.open(params(), scope, nil) |> change("duration", "5", scope)
    # 300 s at 4.5 s holds 66 reps; the pace stays as it is.
    typed = change(form, "reps", "100", scope)
    assert typed.params.reps == 66
    assert typed.params.pace == 4.5
  end

  test "duration stays within the week's time left", %{scope: scope} do
    form = NewWorkoutForm.open(params(), scope, 2_400)
    assert change(form, "duration", "60", scope, 2_400).params.duration == "40:00"

    assert step(change(form, "duration", "40", scope, 2_400), "duration", :up, scope, 2_400).params.duration ==
             "40:00"

    assert change(form, "duration", "1", scope, 2_400).params.duration == "5:00"
  end

  test "what is not a number changes nothing and touches nothing", %{scope: scope} do
    form = NewWorkoutForm.open(params(), scope, nil)

    for {field, value} <- [{"reps", ""}, {"reps", "lots"}, {"pace", "x"}, {"duration", ""}],
        do: assert(change(form, field, value, scope) == form)

    assert change(form, "burpee_type", "jumping_jack", scope) == form
    # The same value again is no change either.
    assert change(form, "reps", "50", scope) == form
  end

  test "steps move duration by five, reps by ten from fifty and pace by half a second", %{
    scope: scope
  } do
    form = NewWorkoutForm.open(params(), scope, nil)
    assert step(form, "duration", :up, scope).params.duration == "25:00"
    assert step(form, "reps", :up, scope).params.reps == 60
    assert step(form, "reps", :up, scope).touched == MapSet.new(["reps"])
    assert step(form, "pace", :up, scope).params.pace == 5.0
    assert step(form, "pace", :down, scope).params.pace == 4.0
  end

  test "a set's size starts unlimited, tightens by five, and goes when the beat is even", %{
    scope: scope
  } do
    form =
      NewWorkoutForm.open(params(%{pacing_style: "unbroken"}), scope, nil)
      |> change("reps", "60", scope)

    assert form.params.max_set_reps == nil
    tight = step(form, "sets", :down, scope)
    assert tight.params.max_set_reps == 55
    assert step(tight, "sets", :up, scope).params.max_set_reps == nil
    assert change(form, "sets", "20", scope).params.max_set_reps == 20
    assert change(change(form, "sets", "20", scope), "sets", "", scope).params.max_set_reps == nil
    # A limit at or above the reps is no limit.
    assert change(form, "sets", "60", scope).params.max_set_reps == nil

    assert change(change(form, "sets", "20", scope), "pacing_style", "even", scope).params.max_set_reps ==
             nil
  end

  test "submitting applies what was typed but not yet sent", %{scope: scope} do
    form = NewWorkoutForm.open(params(), scope, nil)

    submitted =
      NewWorkoutForm.submit(
        form,
        %{"burpee_type" => "six_count", "duration" => "20", "reps" => "80", "pace" => "4.5"},
        scope,
        nil
      )

    assert submitted.params.reps == 80
    assert submitted.touched == MapSet.new(["reps"])
  end
end
