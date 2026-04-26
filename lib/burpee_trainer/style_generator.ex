defmodule BurpeeTrainer.StyleGenerator do
  @moduledoc """
  Pure functional plan generator for named workout archetypes.
  No Ecto, no side effects.

  Takes a `style_name` atom and a `%Progression.Recommendation{}` and
  returns a `%WorkoutPlan{}` ready for editor review (unsaved).

  Each archetype produces a distinct block/set structure:

  6-count archetypes:
    :long_sets   — few large sets (~20 reps), longer rest
    :burst       — many small sets (~7 reps), minimal rest
    :pyramid     — increasing then decreasing sets
    :ladder_up   — progressively increasing sets
    :even        — equal sets, consistent rest

  Navy seal archetypes:
    :even_spaced — equal sets, consistent rest
    :front_loaded — first sets heavy, tapering off
    :descending  — linearly decreasing sets
    :minute_on   — sets sized to fill ~60s of work
  """

  alias BurpeeTrainer.Progression.Recommendation
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  @doc """
  Generate a `%WorkoutPlan{}` for the given archetype and recommendation.
  """
  @spec generate(atom, Recommendation.t()) :: WorkoutPlan.t()
  def generate(style_name, %Recommendation{} = rec) do
    set_sizes = style_generator_sets(style_name, rec)
    style_generator_build_plan(style_name, rec, set_sizes)
  end

  # ---------------------------------------------------------------------------
  # Set-size generators per archetype
  # ---------------------------------------------------------------------------

  defp style_generator_sets(:long_sets, rec) do
    target = max(15, div(rec.burpee_count_suggested, 5))
    n = max(1, round(rec.burpee_count_suggested / target))
    style_generator_distribute_even(rec.burpee_count_suggested, n)
  end

  defp style_generator_sets(:burst, rec) do
    target = clamp(div(rec.burpee_count_suggested, 12), 5, 8)
    n = max(1, round(rec.burpee_count_suggested / target))
    style_generator_distribute_even(rec.burpee_count_suggested, n)
  end

  defp style_generator_sets(:pyramid, rec) do
    k = clamp(round(:math.sqrt(rec.burpee_count_suggested / 5)), 3, 7)
    ratios = Enum.to_list(1..k) ++ Enum.to_list((k - 1)..1//-1)
    style_generator_scale_to_total(ratios, rec.burpee_count_suggested)
  end

  defp style_generator_sets(:ladder_up, rec) do
    n = 6
    style_generator_arithmetic(rec.burpee_count_suggested, n, :ascending)
  end

  defp style_generator_sets(:even, rec) do
    n = max(1, round(rec.burpee_count_suggested / 10))
    style_generator_distribute_even(rec.burpee_count_suggested, n)
  end

  defp style_generator_sets(:even_spaced, rec) do
    n = max(1, round(rec.burpee_count_suggested / 5))
    style_generator_distribute_even(rec.burpee_count_suggested, n)
  end

  defp style_generator_sets(:front_loaded, rec) do
    n = 5
    # 35%, 25%, 18%, 13%, 9% — descending, front-heavy
    ratios = [35, 25, 18, 13, 9]
    sets = style_generator_scale_to_total(ratios, rec.burpee_count_suggested)
    Enum.sort(sets, :desc) |> style_generator_fix_total(rec.burpee_count_suggested, n)
  end

  defp style_generator_sets(:descending, rec) do
    n = 6
    style_generator_arithmetic(rec.burpee_count_suggested, n, :descending)
  end

  defp style_generator_sets(:minute_on, rec) do
    reps_per_min = max(1, round(60.0 / rec.sec_per_rep_suggested))
    n = max(1, round(rec.burpee_count_suggested / reps_per_min))
    style_generator_distribute_even(rec.burpee_count_suggested, n)
  end

  # ---------------------------------------------------------------------------
  # Plan builder (shared)
  # ---------------------------------------------------------------------------

  defp style_generator_build_plan(style_name, rec, set_sizes) do
    set_count = length(set_sizes)
    work_sec = rec.burpee_count_suggested * rec.sec_per_rep_suggested
    total_rest = max(0.0, rec.duration_sec_suggested - work_sec)
    rest_per_set = if set_count > 1, do: round(total_rest / (set_count - 1)), else: 0

    sets =
      set_sizes
      |> Enum.with_index(1)
      |> Enum.map(fn {count, pos} ->
        %Set{
          position: pos,
          burpee_count: max(1, count),
          sec_per_rep: rec.sec_per_rep_suggested,
          sec_per_burpee: Float.round(rec.sec_per_rep_suggested * 0.6, 2),
          end_of_set_rest: if(pos == set_count, do: 0, else: rest_per_set)
        }
      end)

    %WorkoutPlan{
      name: style_generator_plan_name(style_name),
      style_name: Atom.to_string(style_name),
      burpee_type: rec.burpee_type,
      blocks: [%Block{position: 1, repeat_count: 1, sets: sets}]
    }
  end

  # ---------------------------------------------------------------------------
  # Arithmetic helpers
  # ---------------------------------------------------------------------------

  defp style_generator_distribute_even(total, n) do
    base = div(total, n)
    extras = rem(total, n)
    for i <- 0..(n - 1), do: if(i < extras, do: base + 1, else: base)
  end

  # Arithmetic sequence of n terms summing to total. d ≈ base/2.
  defp style_generator_arithmetic(total, n, order) do
    base = max(1, round(total / (n + n * (n - 1) / 4.0)))
    d = max(1, div(base, 2))
    raw = for i <- 0..(n - 1), do: max(1, base + i * d)
    sorted = style_generator_scale_to_total(raw, total)

    case order do
      :ascending -> Enum.sort(sorted)
      :descending -> Enum.sort(sorted, :desc)
    end
  end

  # Scale a list of relative weights to sum exactly to total.
  defp style_generator_scale_to_total(ratios, total) do
    ratio_sum = Enum.sum(ratios)
    scaled = Enum.map(ratios, fn r -> max(1, round(r * total / ratio_sum)) end)
    diff = total - Enum.sum(scaled)

    if diff == 0 do
      scaled
    else
      List.update_at(scaled, 0, fn x -> max(1, x + diff) end)
    end
  end

  # Ensure a pre-sorted list sums to exactly total by adjusting the last set.
  defp style_generator_fix_total(sets, total, _n) do
    diff = total - Enum.sum(sets)
    if diff == 0, do: sets, else: List.update_at(sets, -1, fn x -> max(1, x + diff) end)
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  # ---------------------------------------------------------------------------
  # Plan name labels
  # ---------------------------------------------------------------------------

  defp style_generator_plan_name(:long_sets), do: "Long sets"
  defp style_generator_plan_name(:burst), do: "Burst sets"
  defp style_generator_plan_name(:pyramid), do: "Pyramid"
  defp style_generator_plan_name(:ladder_up), do: "Ladder up"
  defp style_generator_plan_name(:even), do: "Even pacing"
  defp style_generator_plan_name(:even_spaced), do: "Even spaced"
  defp style_generator_plan_name(:front_loaded), do: "Front loaded"
  defp style_generator_plan_name(:descending), do: "Descending"
  defp style_generator_plan_name(:minute_on), do: "Minute on"
end
