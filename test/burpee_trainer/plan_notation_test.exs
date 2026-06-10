defmodule BurpeeTrainer.PlanNotationTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanNotation

  describe "from_pattern/1" do
    test "groups consecutive equal set sizes into repeated blocks" do
      assert PlanNotation.from_pattern([8, 8, 8, 7, 7]) == "3×[8] 2×[7]"
    end

    test "renders single occurrences without a repeat prefix" do
      assert PlanNotation.from_pattern([8, 8, 4]) == "2×[8] [4]"
    end

    test "renders a single set plainly" do
      assert PlanNotation.from_pattern([140]) == "[140]"
    end
  end

  describe "from_segments/1" do
    test "renders multi-set blocks with commas" do
      segments = [
        %{kind: :work, repeat: 5, pattern: [8]},
        %{kind: :work, repeat: 5, pattern: [7, 6]}
      ]

      assert PlanNotation.from_segments(segments) == "5×[8] 5×[7,6]"
    end

    test "renders rests inline" do
      segments = [
        %{kind: :work, repeat: 10, pattern: [8]},
        %{kind: :rest, rest_sec: 30},
        %{kind: :work, repeat: 1, pattern: [6]}
      ]

      assert PlanNotation.from_segments(segments) == "10×[8] (rest 30s) [6]"
    end
  end
end
