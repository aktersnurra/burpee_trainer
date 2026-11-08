defmodule BurpeeTrainer.Coach.CatalogTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Coach.Catalog
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutVideo}

  test "videos order nearest the athlete's level, then by case-insensitive name and ID" do
    videos =
      for {id, name, count} <- [
            {6, "unknown", nil},
            {5, "zero", 0},
            {4, "A", 150},
            {3, "b", 100},
            {2, "a", 100},
            {1, "A", 100}
          ] do
        %WorkoutVideo{
          id: id,
          name: name,
          burpee_type: :six_count,
          burpee_count: count,
          duration_sec: 1200
        }
      end

    # 100 reps is level 1C, 150 is 1D.
    assert Enum.map(Catalog.order_videos(videos, :level_1c), & &1.id) == [1, 2, 3, 4]
    assert Enum.map(Catalog.order_videos(videos, :level_1d), & &1.id) == [4, 1, 2, 3]
    # Equally near on either side, the easier comes first.
    assert Enum.map(Catalog.order_videos(videos, :level_1b), & &1.id) == [1, 2, 3, 4]
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

  test "unknown video exclusion and plan levels" do
    assert Catalog.video_level(%WorkoutVideo{burpee_type: :six_count, burpee_count: nil}) == nil

    # Forty minutes holds 1.5 times the reps: 200 in 40 minutes is 133 in 20, not 200.
    assert Catalog.plan_level(%WorkoutPlan{
             burpee_type: :six_count,
             target_reps: 200,
             target_duration_sec: 2400
           }) ==
             Catalog.plan_level(%WorkoutPlan{
               burpee_type: :six_count,
               target_reps: 133,
               target_duration_sec: 1200
             })

    refute Catalog.plan_level(%WorkoutPlan{
             burpee_type: :six_count,
             target_reps: 200,
             target_duration_sec: 2400
           }) == :level_2
  end

  test "the drawer opens on both types, the athlete's level and every level above" do
    filters = Catalog.default_filters(:level_1c)
    assert filters.types == MapSet.new([:six_count, :navy_seal])

    assert filters.levels ==
             MapSet.new([:level_1c, :level_1d, :level_2, :level_3, :level_4, :graduated])

    easy = %WorkoutPlan{burpee_type: :six_count, target_reps: 10, target_duration_sec: 1200}
    hard = %WorkoutPlan{burpee_type: :six_count, target_reps: 400, target_duration_sec: 1200}
    assert Catalog.filter([easy, hard], filters, &Catalog.plan_level/1) == [hard]
  end

  test "the coach's ranking leads, unknown and repeated IDs dropped" do
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
  end
end
