defmodule BurpeeTrainer.Workouts.CaptureTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Workouts.Capture

  describe "from_fields/1" do
    test "legacy nil mode loads as logged" do
      assert {:ok, %{mode: :logged}} =
               Capture.from_fields(%{
                 capture_mode: nil,
                 cadence_ms: nil,
                 target_pace_sec: nil,
                 pace_consistency: nil
               })
    end

    test "tracked requires cadence and consistency" do
      assert {:error, :tracked_missing_cadence} =
               Capture.from_fields(%{
                 capture_mode: "tracked",
                 cadence_ms: nil,
                 target_pace_sec: 4.0,
                 pace_consistency: 0.9
               })

      assert {:error, :tracked_missing_consistency} =
               Capture.from_fields(%{
                 capture_mode: "tracked",
                 cadence_ms: "[1000,2000]",
                 target_pace_sec: 4.0,
                 pace_consistency: nil
               })
    end

    test "tracked decodes cadence" do
      assert {:ok,
              %{
                mode: :tracked,
                cadence_ms: [1000, 2500, 4100],
                target_pace_sec: 4.0,
                consistency: 0.95
              }} =
               Capture.from_fields(%{
                 capture_mode: "tracked",
                 cadence_ms: "[1000,2500,4100]",
                 target_pace_sec: 4.0,
                 pace_consistency: 0.95
               })
    end

    test "timed rejects cadence" do
      assert {:error, :timed_has_cadence} =
               Capture.from_fields(%{
                 capture_mode: "timed",
                 cadence_ms: "[1000]",
                 target_pace_sec: 4.0,
                 pace_consistency: nil
               })
    end

    test "logged rejects capture-only fields" do
      assert {:error, :logged_has_capture_data} =
               Capture.from_fields(%{
                 capture_mode: "logged",
                 cadence_ms: nil,
                 target_pace_sec: 4.0,
                 pace_consistency: nil
               })
    end
  end
end
