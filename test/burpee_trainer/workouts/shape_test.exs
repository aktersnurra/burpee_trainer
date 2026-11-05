defmodule BurpeeTrainer.Workouts.ShapeTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Workouts.Shape

  defp work(reps, every, move \\ nil),
    do: %{
      "kind" => "work",
      "reps" => reps,
      "sec_per_rep" => every,
      "sec_per_burpee" => move || every
    }

  defp rest(seconds), do: %{"kind" => "rest", "duration_sec" => seconds}

  test "sets read as how many of how many, then the whole pause between them" do
    events = [work(3, 8, 5), rest(267), work(3, 8, 5), rest(267), work(3, 8, 5)]
    assert Shape.describe(%{"events" => events}) == "3 sets of 3 · 4:30 rest"
  end

  test "what varies reads as its range" do
    events = [work(10, 4), rest(45), work(5, 5), rest(120), work(5, 5)]
    assert Shape.describe(%{"events" => events}) == "3 sets of 5–10 · 45s–2:00 rest"
  end

  test "a workout with no rest reads as its beat, all the way" do
    assert Shape.describe(%{"events" => [work(44, 1200 / 44)]}) ==
             "One rep every 27 s, all the way"

    assert Shape.describe(%{"events" => [work(5, 4), work(5, 5.5)]}) ==
             "One rep every 4–5.5 s, all the way"
  end

  test "one set before a final rest has no rest between sets" do
    assert Shape.describe(%{"events" => [work(100, 5.5), rest(650)]}) == "1 set of 100"
  end
end
