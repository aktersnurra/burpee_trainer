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

  test "even sets read as count × reps, the beat and the whole pause between sets" do
    events = [work(3, 8, 5), rest(267), work(3, 8, 5), rest(267), work(3, 8, 5)]
    assert Shape.describe(%{"events" => events}) == "3 × 3 · every 8s · 4:30 rest"
  end

  test "what varies reads as its range; a set with no rest after it reads as no rest" do
    events = [work(10, 4), rest(45), work(5, 5), rest(120), work(5, 5)]
    assert Shape.describe(%{"events" => events}) == "3 sets of 5–10 · every 4–5s · 45s–2:00 rest"

    assert Shape.describe(%{"events" => [work(5, 4), work(5, 4)]}) == "2 × 5 · every 4s · no rest"
  end

  test "one set has no rest" do
    assert Shape.describe(%{"events" => [work(100, 5.5)]}) == "1 set of 100 · every 5.5s"
  end
end
