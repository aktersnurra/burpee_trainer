defmodule BurpeeTrainer.Coach.CatalogTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Coach.Catalog
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutVideo}

  test "videos order by known level, case-insensitive name and ID" do
    videos =
      for {id, name, count} <- [
            {6, "unknown", nil},
            {5, "zero", 0},
            {4, "A", 150},
            {3, "b", 100},
            {2, "a", 100},
            {1, "A", 100}
          ] do
        %WorkoutVideo{id: id, name: name, burpee_type: :six_count, burpee_count: count}
      end

    assert Enum.map(Catalog.order_videos(videos), & &1.id) == [1, 2, 3, 4]
  end

  test "omitted plans use all deterministic tie breakers" do
    plans =
      for {id, type, duration, reps, name} <- [
            {6, :navy_seal, 1200, 40, "A"},
            {5, :six_count, 1300, 100, "A"},
            {4, :six_count, 1200, 150, "A"},
            {3, :six_count, 1200, 100, "B"},
            {2, :six_count, 1200, 100, "a"},
            {1, :six_count, 1200, 100, "A"}
          ] do
        %WorkoutPlan{
          id: id,
          burpee_type: type,
          target_duration_sec: duration,
          target_reps: reps,
          name: name
        }
      end

    assert Enum.map(
             Catalog.order_plans(
               plans,
               [],
               %{burpee_type: :six_count, duration_sec: 1200},
               :level_1c
             ),
             & &1.id
           ) == [1, 2, 3, 4, 5, 6]
  end

  test "real current-next defaults and unknown video exclusion" do
    assert Catalog.default_filters(:level_1c).levels == MapSet.new([:level_1c, :level_1d])
    assert Catalog.default_filters(:graduated).levels == MapSet.new([:graduated])
    assert Catalog.video_level(%WorkoutVideo{burpee_type: :six_count, burpee_count: nil}) == nil

    assert Catalog.plan_level(%WorkoutPlan{
             burpee_type: :six_count,
             target_reps: 200,
             target_duration_sec: 2400
           }) == :level_2
  end

  test "filtering preserves the coach-ranked subsequence" do
    plans =
      for {id, type, reps} <- [{1, :six_count, 100}, {2, :navy_seal, 40}, {3, :six_count, 150}],
          do: %WorkoutPlan{
            id: id,
            name: "Plan #{id}",
            burpee_type: type,
            target_reps: reps,
            target_duration_sec: 1200
          }

    ranked =
      Catalog.order_plans(
        plans,
        [2, 3, 2, 999],
        %{burpee_type: :six_count, duration_sec: 1200},
        :level_1c
      )

    assert Enum.map(ranked, & &1.id) == [2, 3, 1]
    filters = %{types: MapSet.new([:six_count]), levels: MapSet.new([:level_1c, :level_1d])}
    assert Enum.map(Catalog.filter(ranked, filters, &Catalog.plan_level/1), & &1.id) == [3, 1]
  end
end
