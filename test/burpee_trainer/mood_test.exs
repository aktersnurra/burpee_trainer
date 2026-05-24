defmodule BurpeeTrainer.MoodTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Mood

  test "parse accepts valid mood strings" do
    assert {:ok, -1} = Mood.parse("-1")
    assert {:ok, 0} = Mood.parse("0")
    assert {:ok, 1} = Mood.parse("1")
  end

  test "parse rejects invalid mood strings" do
    assert {:error, {:invalid_mood, "2"}} = Mood.parse("2")
    assert {:error, {:invalid_mood, "bad"}} = Mood.parse("bad")
  end
end
