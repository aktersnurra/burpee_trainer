defmodule BurpeeTrainer.Insights.ValidatorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias BurpeeTrainer.Insights.Validator

  @metrics %{
    "week.minutes" => %{value: 40, unit: :minutes, label: "minutes"},
    "session.pace_sec" => %{value: -4.8, unit: :seconds, label: "pace"}
  }
  defp insight(text, ids \\ ["week.minutes"]),
    do: %{"headline" => "Session saved", "points" => [%{"text" => text, "metric_ids" => ids}]}

  test "formatted cited values only" do
    assert {:ok, _} =
             Validator.validate(
               insight("40 minutes; change -4.8 seconds.", ["week.minutes", "session.pace_sec"]),
               @metrics
             )

    assert {:error, {:unsupported_number, "45"}} =
             Validator.validate(insight("45 minutes"), @metrics)

    assert {:error, {:unknown_metric, "other"}} =
             Validator.validate(insight("40 minutes", ["other"]), @metrics)

    assert {:error, {:unsupported_number, "40"}} =
             Validator.validate(%{"headline" => "40 minutes", "points" => []}, @metrics)
  end

  test "signed, grouped, exponential and unicode digits cannot piggyback on partial matches" do
    for token <- ["-40", "+40", "40.0", "4e1", "1,040", "４０", "٤٠", "−40", ".40"] do
      assert {:error, _} = Validator.validate(insight("#{token} minutes"), @metrics)
    end
  end

  test "shape, empty citations and bounds" do
    assert {:error, :invalid_shape} = Validator.validate(insight("x", [nil]), @metrics)

    assert {:error, {:unsupported_number, "40"}} =
             Validator.validate(insight("40 minutes", []), @metrics)

    assert {:error, :too_long} = Validator.validate(insight(String.duplicate("a", 161)), @metrics)

    assert {:error, :too_many_points} =
             Validator.validate(
               %{
                 "headline" => "h",
                 "points" => List.duplicate(%{"text" => "x", "metric_ids" => []}, 4)
               },
               @metrics
             )

    assert {:error, :invalid_shape} =
             Validator.validate(%{"headline" => "h", "points" => [nil]}, @metrics)
  end

  test "categorical level tags never license embedded digits" do
    for value <- ["level_1a", "level_4"] do
      metrics = %{"level.six_count" => %{value: value, unit: :level, label: "level"}}

      assert {:ok, _} =
               Validator.validate(
                 insight("Current level #{value}.", ["level.six_count"]),
                 metrics
               )

      for number <- ["1", "4"] do
        assert {:error, {:unsupported_number, ^number}} =
                 Validator.validate(
                   insight("#{value}, #{number} reps.", ["level.six_count"]),
                   metrics
                 )
      end
    end
  end

  test "UTF-8 and headline/text length boundaries fail closed" do
    assert {:ok, _} =
             Validator.validate(
               %{
                 "headline" => String.duplicate("h", 80),
                 "points" => [%{"text" => String.duplicate("é", 160), "metric_ids" => []}]
               },
               @metrics
             )

    assert {:error, :too_long} =
             Validator.validate(
               %{"headline" => String.duplicate("h", 81), "points" => []},
               @metrics
             )

    assert {:error, :invalid_shape} =
             Validator.validate(%{"headline" => <<255>>, "points" => []}, @metrics)

    assert {:error, :invalid_shape} = Validator.validate(insight(<<255>>), @metrics)

    assert {:error, :invalid_shape} =
             Validator.validate(%{"headline" => "  ", "points" => []}, @metrics)
  end

  property "formatted signed decimal metrics are accepted without decimal substring matching" do
    check all(n <- integer(-1000..1000)) do
      metric = %{value: n / 10, unit: :seconds, label: "change"}
      token = BurpeeTrainer.Insights.Metrics.format(metric)

      assert {:ok, _} =
               Validator.validate(insight("#{token} seconds", ["pace.change_6w.six_count"]), %{
                 "pace.change_6w.six_count" => metric
               })
    end
  end

  property "uncited distinct integers are always rejected" do
    check all(n <- integer(0..100_000), n != 40) do
      assert {:error, {:unsupported_number, token}} =
               Validator.validate(insight("#{n} minutes"), @metrics)

      assert token == Integer.to_string(n)
    end
  end

  describe "validate_summary/2" do
    @summary_metrics %{
      "goal.3.best_reps" => %{value: 120, unit: :reps, label: "best"},
      "goal.3.days_left" => %{value: 52, unit: :days, label: "days"},
      "session.pace_sec" => %{value: -4.8, unit: :seconds, label: "pace"}
    }

    defp summary(text, ids \\ ["goal.3.best_reps", "goal.3.days_left"]),
      do: %{"text" => text, "metric_ids" => ids}

    test "accepts text whose numbers are cited formatted values" do
      summary = summary("Best so far is 120 reps. 52 days left to reach the goal.")
      assert {:ok, ^summary} = Validator.validate_summary(summary, @summary_metrics)

      assert {:ok, _} =
               Validator.validate_summary(
                 summary("Pace moved -4.8 seconds per rep.", ["session.pace_sec"]),
                 @summary_metrics
               )
    end

    test "rejects unsupported numbers and unknown ids" do
      assert {:error, {:unsupported_number, "130"}} =
               Validator.validate_summary(summary("Best so far is 130 reps."), @summary_metrics)

      assert {:error, {:unsupported_number, "52"}} =
               Validator.validate_summary(
                 summary("52 days left.", ["goal.3.best_reps"]),
                 @summary_metrics
               )

      assert {:error, {:unknown_metric, "goal.9.best_reps"}} =
               Validator.validate_summary(
                 summary("Keep going.", ["goal.9.best_reps"]),
                 @summary_metrics
               )
    end

    test "rejects empty, over-long and more-than-two-sentence text" do
      assert {:error, :invalid_shape} =
               Validator.validate_summary(summary("  "), @summary_metrics)

      assert {:error, :too_long} =
               Validator.validate_summary(summary(String.duplicate("a", 281)), @summary_metrics)

      assert {:error, :too_many_sentences} =
               Validator.validate_summary(
                 summary("Good week. Keep going! Rest well?"),
                 @summary_metrics
               )

      assert {:error, :invalid_shape} =
               Validator.validate_summary(%{"text" => "Fine."}, @summary_metrics)
    end

    test "a sentence starts with a capital or a number, whether or not the last one ends" do
      assert {:error, :too_many_sentences} =
               Validator.validate_summary(
                 summary("Good week. Keep going! Rest well"),
                 @summary_metrics
               )

      assert {:ok, _} =
               Validator.validate_summary(
                 summary("Best so far is 120 reps, approx. half unbroken. 52 days left."),
                 @summary_metrics
               )
    end
  end
end
