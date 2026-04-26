defmodule BurpeeTrainer.StyleRecommenderTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.StyleRecommender
  alias BurpeeTrainer.StyleRecommender.StyleSuggestion
  alias BurpeeTrainer.Progression.Recommendation

  defp rec(overrides \\ %{}) do
    Map.merge(
      %Recommendation{
        goal_id: nil,
        burpee_type: :six_count,
        phase: :build_2,
        trend_status: :on_track,
        burpee_count_suggested: 100,
        duration_sec_suggested: 1200,
        sec_per_rep_suggested: 5.0,
        rationale: "Test",
        weeks_remaining: 4,
        burpee_count_projected_at_goal: nil
      },
      overrides
    )
  end

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        burpee_type: :six_count,
        mood: 0,
        level: :level_1c,
        time_of_day_bucket: "morning",
        sessions: [],
        performances: [],
        progression_rec: rec()
      },
      overrides
    )
  end

  describe "recommend/1" do
    test "returns exactly 3 suggestions" do
      suggestions = StyleRecommender.recommend(context())
      assert length(suggestions) == 3
    end

    test "each suggestion has a plan, score, and rationale" do
      for %StyleSuggestion{plan: plan, score: score, rationale: rationale} <-
            StyleRecommender.recommend(context()) do
        assert plan != nil
        assert is_float(score) or is_integer(score)
        assert is_binary(rationale) and rationale != ""
      end
    end

    test "prior score is @prior_mean (0.85) before any plateau boost with zero performances" do
      # With no sessions (no plateau boost), no mood/time modifiers, base score = prior.
      suggestions = StyleRecommender.recommend(context(%{mood: 0, time_of_day_bucket: "morning"}))
      # All scores should be prior_mean + plateau_boost (0.85 + 0.15 = 1.0) since no styles
      # have been used recently.
      for s <- suggestions, do: assert(s.score == 0.85 + 0.15)
    end

    test "level filter: long_sets (1C+) not returned for level_1b user" do
      suggestions = StyleRecommender.recommend(context(%{level: :level_1b}))
      style_names = Enum.map(suggestions, & &1.style_name)
      refute :long_sets in style_names
    end

    test "level filter: long_sets returned for level_1c user" do
      suggestions = StyleRecommender.recommend(context(%{level: :level_1c}))
      style_names = Enum.map(suggestions, & &1.style_name)
      assert :long_sets in style_names
    end

    test "mood -1 boosts burst into top results" do
      suggestions = StyleRecommender.recommend(context(%{mood: -1}))
      top_style = hd(suggestions).style_name
      assert top_style == :burst
    end

    test "mood +1 boosts long_sets" do
      suggestions = StyleRecommender.recommend(context(%{mood: 1}))
      style_names = Enum.map(suggestions, & &1.style_name)
      assert :long_sets in style_names
    end

    test "plateau override: recently used style has lower score than unused" do
      used_session = %{
        style_name: "burst",
        inserted_at: ~U[2026-04-25 10:00:00Z],
        burpee_type: :six_count
      }

      with_plateau = StyleRecommender.recommend(context(%{sessions: [used_session]}))
      without_plateau = StyleRecommender.recommend(context(%{sessions: []}))

      burst_with = Enum.find(with_plateau, &(&1.style_name == :burst))
      burst_without = Enum.find(without_plateau, &(&1.style_name == :burst))

      # burst used recently → no plateau boost → lower score
      if burst_with && burst_without do
        assert burst_with.score < burst_without.score
      end
    end

    test "navy_seal context returns navy_seal archetypes only" do
      navy_rec = rec(%{burpee_type: :navy_seal})

      suggestions =
        StyleRecommender.recommend(context(%{burpee_type: :navy_seal, progression_rec: navy_rec}))

      for s <- suggestions do
        assert s.style_name in [:even_spaced, :front_loaded, :descending, :minute_on]
      end
    end

    test "navy_seal at level_1a: only even_spaced returned (others need higher level)" do
      navy_rec = rec(%{burpee_type: :navy_seal})

      suggestions =
        StyleRecommender.recommend(
          context(%{burpee_type: :navy_seal, level: :level_1a, progression_rec: navy_rec})
        )

      # Only :even_spaced is available at level_1a for navy_seal
      assert length(suggestions) == 1
      assert hd(suggestions).style_name == :even_spaced
    end

    test "session_count is 0 with no performances" do
      for %StyleSuggestion{session_count: n} <- StyleRecommender.recommend(context()) do
        assert n == 0
      end
    end
  end
end
