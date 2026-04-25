defmodule BurpeeTrainer.StyleRecommender do
  @moduledoc """
  Pure functional style recommender. No Ecto, no side effects.

  Scores eligible archetypes via a Bayesian model seeded from
  `StylePerformance` records, applies mood and time-of-day modifiers,
  boosts styles unused in the last 3 sessions (plateau override), and
  returns the top 3 as `%StyleSuggestion{}` structs.

  ## Contextual bandit (upgrade path)
  Context = `(mood, level, time_of_day_bucket)`, arms = archetypes,
  reward = completion_ratio. Currently uses a Thompson-sampling-inspired
  Bayesian prior; can be extended by persisting per-context performance
  data in `StylePerformance` and adjusting priors per context bucket.
  """

  alias BurpeeTrainer.StyleGenerator

  @prior_weight 3
  @prior_mean 0.85
  @plateau_boost 0.15

  # Archetypes per burpee type with minimum level requirement.
  @archetypes %{
    six_count: [
      %{name: :long_sets, min_level: :level_1c},
      %{name: :burst, min_level: :level_1a},
      %{name: :pyramid, min_level: :level_1b},
      %{name: :ladder_up, min_level: :level_1b},
      %{name: :even, min_level: :level_1a}
    ],
    navy_seal: [
      %{name: :even_spaced, min_level: :level_1a},
      %{name: :front_loaded, min_level: :level_1b},
      %{name: :descending, min_level: :level_1c},
      %{name: :minute_on, min_level: :level_1d}
    ]
  }

  @level_order [:level_1a, :level_1b, :level_1c, :level_1d, :level_2, :level_3, :level_4, :graduated]

  # Mood modifier deltas keyed by style_name.
  @mood_modifiers %{
    -1 => %{burst: +0.10, even: +0.05, long_sets: -0.10, descending: -0.10},
    +1 => %{long_sets: +0.10, pyramid: +0.05, descending: +0.05, burst: -0.05}
  }

  # Time-of-day modifier deltas keyed by bucket string.
  @time_modifiers %{
    "evening" => %{burst: +0.05, long_sets: -0.05, descending: -0.05},
    "night" => %{burst: +0.10, long_sets: -0.10, descending: -0.10, even: +0.05}
  }

  defmodule StyleSuggestion do
    @moduledoc false
    @enforce_keys [:style_name, :score, :session_count, :plan, :rationale]
    defstruct [:style_name, :score, :session_count, :plan, :rationale]

    @type t :: %__MODULE__{
            style_name: atom,
            score: float,
            session_count: integer,
            plan: term,
            rationale: String.t()
          }
  end

  @doc """
  Return the top 3 style suggestions for the given context.

  Input map keys:
    - `burpee_type` — `:six_count | :navy_seal`
    - `mood` — `-1 | 0 | 1`
    - `level` — level atom (from `BurpeeTrainer.Levels.current_level/1`)
    - `time_of_day_bucket` — `"morning" | "afternoon" | "evening" | "night"`
    - `sessions` — recent `%WorkoutSession{}` list (for plateau detection)
    - `performances` — `%StylePerformance{}` list for this user
    - `progression_rec` — `%Recommendation{}` from `Progression.recommend/2`
  """
  @spec recommend(map) :: [StyleSuggestion.t()]
  def recommend(%{
        burpee_type: burpee_type,
        mood: mood,
        level: level,
        time_of_day_bucket: bucket,
        sessions: sessions,
        performances: performances,
        progression_rec: rec
      }) do
    eligible = style_recommender_eligible(burpee_type, level)
    perf_by_style = Map.new(performances, &{&1.style_name, &1})
    recent_styles = style_recommender_recent_styles(sessions, 3)

    eligible
    |> Enum.map(fn %{name: style_name} ->
      perf = Map.get(perf_by_style, Atom.to_string(style_name))
      score =
        style_recommender_bayesian_score(perf)
        |> style_recommender_apply_mood(style_name, mood)
        |> style_recommender_apply_time(style_name, bucket)
        |> style_recommender_apply_plateau(style_name, recent_styles)

      {style_name, score, (perf && perf.session_count) || 0}
    end)
    |> Enum.sort_by(fn {_, score, _} -> score end, :desc)
    |> Enum.take(3)
    |> Enum.map(fn {style_name, score, session_count} ->
      %StyleSuggestion{
        style_name: style_name,
        score: score,
        session_count: session_count,
        plan: StyleGenerator.generate(style_name, rec),
        rationale: style_recommender_rationale(style_name, mood, bucket)
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp style_recommender_eligible(burpee_type, level) do
    user_idx = Enum.find_index(@level_order, &(&1 == level)) || 0

    Map.get(@archetypes, burpee_type, [])
    |> Enum.filter(fn %{min_level: min} ->
      min_idx = Enum.find_index(@level_order, &(&1 == min)) || 0
      user_idx >= min_idx
    end)
  end

  defp style_recommender_bayesian_score(nil) do
    @prior_weight * @prior_mean / @prior_weight
  end

  defp style_recommender_bayesian_score(perf) do
    n = perf.session_count
    avg = if n > 0, do: perf.completion_ratio_sum / n, else: @prior_mean
    (@prior_weight * @prior_mean + n * avg) / (@prior_weight + n)
  end

  defp style_recommender_apply_mood(score, style_name, mood) do
    delta = get_in(@mood_modifiers, [mood, style_name]) || 0.0
    score + delta
  end

  defp style_recommender_apply_time(score, style_name, bucket) do
    delta = get_in(@time_modifiers, [bucket, style_name]) || 0.0
    score + delta
  end

  defp style_recommender_apply_plateau(score, style_name, recent_styles) do
    if style_name in recent_styles, do: score, else: score + @plateau_boost
  end

  defp style_recommender_recent_styles(sessions, n) do
    sessions
    |> Enum.reject(fn s -> is_nil(s.style_name) end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.take(n)
    |> Enum.map(fn s -> String.to_existing_atom(s.style_name) end)
  rescue
    _ -> []
  end

  defp style_recommender_rationale(:long_sets, mood, _bucket) do
    base = "Long sets build lactate threshold and mental endurance."
    if mood == -1, do: base <> " Maybe ambitious today — consider starting conservatively.", else: base
  end

  defp style_recommender_rationale(:burst, mood, bucket) do
    base = "Short explosive sets keep intensity high."
    cond do
      mood == -1 -> base <> " Good match for low energy — high output, manageable sets."
      bucket in ["evening", "night"] -> base <> " Well suited for later in the day."
      true -> base
    end
  end

  defp style_recommender_rationale(:pyramid, _mood, _bucket) do
    "Pyramid builds into peak load then tapers — a structured progression within the session."
  end

  defp style_recommender_rationale(:ladder_up, _mood, _bucket) do
    "Ladder up progressively loads the session — each set harder than the last."
  end

  defp style_recommender_rationale(:even, _mood, _bucket) do
    "Consistent pacing across all sets — reliable and easy to execute on any day."
  end

  defp style_recommender_rationale(:even_spaced, _mood, _bucket) do
    "Equal sets with consistent rest — steady state for Navy Seal burpees."
  end

  defp style_recommender_rationale(:front_loaded, _mood, _bucket) do
    "Heavy first half lets you bank reps early when energy is highest."
  end

  defp style_recommender_rationale(:descending, mood, _bucket) do
    base = "Descending sets let you push hard early and recover through the session."
    if mood == -1, do: base <> " First set will be demanding — be ready.", else: base
  end

  defp style_recommender_rationale(:minute_on, _mood, _bucket) do
    "Minute-on structure aligns with a clock cadence — simple to track and pace."
  end
end
