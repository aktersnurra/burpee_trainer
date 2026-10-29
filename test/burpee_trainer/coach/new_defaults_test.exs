defmodule BurpeeTrainer.Coach.NewDefaultsTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Coach.NewDefaults

  describe "duration" do
    test "steps of five up to what the week has left, which is always an option" do
      assert NewDefaults.durations(2_400) == [5, 10, 15, 20, 25, 30, 35, 40]
      assert NewDefaults.durations(1_500) == [5, 10, 15, 20, 25]
      assert NewDefaults.durations(1_380) == [5, 10, 15, 20, 23]
      assert NewDefaults.durations(130) == [2]
    end

    test "never past the week's 80 minutes, whatever is reported left" do
      assert List.last(NewDefaults.durations(9_000)) == 80
      assert List.last(NewDefaults.durations(nil)) == 80
    end

    test "starts at a standard session, or at what is left when that is less" do
      assert NewDefaults.default_duration(4_800) == 20
      assert NewDefaults.default_duration(600) == 10
      assert NewDefaults.default_duration(130) == 2
    end

    test "a step moves to the next option and stops at the ends" do
      assert NewDefaults.step_duration(20, :up, 2_400) == 25
      assert NewDefaults.step_duration(20, :down, 2_400) == 15
      assert NewDefaults.step_duration(40, :up, 2_400) == 40
      assert NewDefaults.step_duration(5, :down, 2_400) == 5
      assert NewDefaults.step_duration(20, :up, 1_380) == 23
      assert NewDefaults.step_duration(23, :up, 1_380) == 23
    end
  end

  describe "reps" do
    test "with no history they start from the next level" do
      scope = scope_fixture()
      assert NewDefaults.suggested_reps(scope, :six_count, 1_200) == 50
      assert NewDefaults.suggested_reps(scope, :navy_seal, 1_200) == 20
    end

    test "with a recent session they start from the best, scaled to the duration" do
      scope = scope_fixture()

      free_form_session_fixture(scope.user, %{
        "burpee_count_actual" => 100,
        "duration_sec_actual" => 1_200
      })

      assert NewDefaults.suggested_reps(scope, :six_count, 1_200) == 100
      assert NewDefaults.suggested_reps(scope, :six_count, 600) == 50
      # A longer session does not hold the same rate for longer.
      assert NewDefaults.suggested_reps(scope, :six_count, 2_400) == 180
    end

    test "a step is five, never below five" do
      assert NewDefaults.step_reps(100, :up) == 105
      assert NewDefaults.step_reps(100, :down) == 95
      assert NewDefaults.step_reps(5, :down) == 5
    end
  end

  describe "pace" do
    test "starts mid-reference, or faster when the reps leave little room for recovery" do
      assert NewDefaults.default_pace(:six_count, 100, 1_200) == 4.5
      assert NewDefaults.default_pace(:navy_seal, 50, 1_200) == 8.0
      assert NewDefaults.default_pace(:six_count, 250, 1_200) == 4.0
    end

    test "a step is half a second, never below half a second" do
      assert NewDefaults.step_pace(4.5, :up) == 5.0
      assert NewDefaults.step_pace(4.5, :down) == 4.0
      assert NewDefaults.step_pace(0.5, :down) == 0.5
    end

    test "the reps that fit are the ones whose movement fits the duration" do
      assert NewDefaults.max_reps(5.0, 1_200) == 240
      assert NewDefaults.max_reps(4.5, 1_200) == 266
    end
  end

  describe "set size" do
    test "steps of five below the total, then no limit, which is the start" do
      assert NewDefaults.set_sizes(30) == [5, 10, 15, 20, 25, nil]
      assert NewDefaults.set_sizes(31) == [5, 10, 15, 20, 25, 30, nil]
      assert NewDefaults.set_sizes(5) == [nil]
    end

    test "a step tightens or loosens along the list and stops at its ends" do
      assert NewDefaults.step_set_size(nil, :down, 30) == 25
      assert NewDefaults.step_set_size(25, :up, 30) == nil
      assert NewDefaults.step_set_size(nil, :up, 30) == nil
      assert NewDefaults.step_set_size(5, :down, 30) == 5
      assert NewDefaults.step_set_size(nil, :down, 5) == nil
    end
  end
end
