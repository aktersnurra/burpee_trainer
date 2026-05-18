defmodule BurpeeTrainer.WorkoutFeedTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.WorkoutFeed
  alias BurpeeTrainer.WorkoutFeed.WorkoutItem

  describe "list/2" do
    test "returns plans and videos as WorkoutItems" do
      user = user_fixture()
      plan = plan_fixture(user, %{"name" => "My Plan", "burpee_type" => "six_count"})
      video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 1200})

      items = WorkoutFeed.list(user)

      assert length(items) == 2
      assert Enum.all?(items, &match?(%WorkoutItem{}, &1))
      titles = Enum.map(items, & &1.title)
      assert "My Plan" in titles
      assert "BDT Video" in titles
    end

    test "plans sort before videos when no source filter" do
      user = user_fixture()
      _plan = plan_fixture(user)
      _video = video_fixture(%{name: "V", burpee_type: :six_count, duration_sec: 600})

      items = WorkoutFeed.list(user)

      plan_item = Enum.find(items, &(&1.kind == :plan))
      video_item = Enum.find(items, &(&1.kind == :video))
      plan_idx = Enum.find_index(items, &(&1.id == plan_item.id && &1.kind == :plan))
      video_idx = Enum.find_index(items, &(&1.id == video_item.id && &1.kind == :video))
      assert plan_idx < video_idx
    end

    test "source filter :mine returns only plans" do
      user = user_fixture()
      _plan = plan_fixture(user)
      _video = video_fixture(%{name: "V", burpee_type: :six_count, duration_sec: 600})

      items = WorkoutFeed.list(user, %{source: :mine})

      assert Enum.all?(items, &(&1.kind == :plan))
    end

    test "source filter :videos returns only videos" do
      user = user_fixture()
      _plan = plan_fixture(user)
      _video = video_fixture(%{name: "V", burpee_type: :six_count, duration_sec: 600})

      items = WorkoutFeed.list(user, %{source: :videos})

      assert Enum.all?(items, &(&1.kind == :video))
    end

    test "burpee_type filter restricts both plans and videos" do
      user = user_fixture()
      _six = plan_fixture(user, %{"burpee_type" => "six_count"})
      _seal = plan_fixture(user, %{"name" => "SEAL plan", "burpee_type" => "navy_seal"})
      _video = video_fixture(%{name: "V", burpee_type: :navy_seal, duration_sec: 600})

      items = WorkoutFeed.list(user, %{burpee_type: :six_count})

      assert Enum.all?(items, &(&1.burpee_type == :six_count))
    end

    test "level filter restricts items by level" do
      user = user_fixture()
      # plan with 10 reps → :level_1a
      _low = plan_fixture(user)
      # plan with 200 reps → :level_2 for six_count
      _high =
        plan_fixture(user, %{
          "name" => "Big plan",
          "blocks" => [
            %{
              "position" => 1,
              "repeat_count" => 1,
              "sets" => [
                %{
                  "position" => 1,
                  "burpee_count" => 200,
                  "sec_per_rep" => 6.0,
                  "sec_per_burpee" => 3.0,
                  "end_of_set_rest" => 0
                }
              ]
            }
          ]
        })

      items = WorkoutFeed.list(user, %{level: :level_2})

      assert Enum.all?(items, &(&1.level == :level_2))
    end

    test "property: list with filter equals filtered union of plans and videos" do
      user = user_fixture()
      _p1 = plan_fixture(user, %{"burpee_type" => "six_count"})
      _p2 = plan_fixture(user, %{"name" => "P2", "burpee_type" => "navy_seal"})
      _v1 = video_fixture(%{name: "V1", burpee_type: :six_count, duration_sec: 600})
      _v2 = video_fixture(%{name: "V2", burpee_type: :navy_seal, duration_sec: 900})

      filter = %{burpee_type: :six_count}
      filtered = WorkoutFeed.list(user, filter)

      unfiltered = WorkoutFeed.list(user)

      expected_ids =
        unfiltered
        |> Enum.filter(&(&1.burpee_type == :six_count))
        |> Enum.map(&{&1.kind, &1.id})
        |> MapSet.new()

      actual_ids = filtered |> Enum.map(&{&1.kind, &1.id}) |> MapSet.new()
      assert actual_ids == expected_ids
    end
  end
end
