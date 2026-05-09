defmodule BurpeeTrainer.PlanWizard.Errors do
  @moduledoc """
  Error message strings produced by the solver pipeline.

  Centralised so phrasing is preserved verbatim from the legacy
  `PlanWizard` implementation — the LiveView edit page asserts on these
  strings.
  """

  @placement_tolerance_sec 30

  def placement_tolerance_sec, do: @placement_tolerance_sec

  def pace_too_fast(sec_per_burpee, floor, burpee_type) do
    "pace #{:erlang.float_to_binary(sec_per_burpee * 1.0, decimals: 2)}s/rep is below the " <>
      "minimum #{:erlang.float_to_binary(floor * 1.0, decimals: 2)}s/rep for " <>
      "#{burpee_type} (graduation pace floor)"
  end

  def work_exceeds_target(work_sec, target_sec) do
    "work time (#{round(work_sec)}s) exceeds target duration (#{target_sec}s) — " <>
      "reduce reps or increase target duration"
  end

  def rest_exceeds_pace_floor(total_rest_sec, sec_per_burpee, max_rest) do
    "total additional rest (#{total_rest_sec}s) requires cadence below " <>
      "#{:erlang.float_to_binary(sec_per_burpee * 1.0, decimals: 2)}s/rep floor — " <>
      "max #{max_rest}s additional rest for this pace and rep count"
  end

  def work_plus_rests_exceed_target(work_sec, total_rest_sec, target_sec) do
    "work (#{round(work_sec)}s) + additional rests (#{round(total_rest_sec)}s) " <>
      "exceeds target duration (#{target_sec}s)"
  end

  def reps_per_set_invalid do
    "reps per set must be a positive integer"
  end

  def cannot_place_rest_no_boundaries(target_min) do
    "no boundaries available for rest at min #{target_min}"
  end

  def cannot_place_rest_only_one_set(target_min) do
    "cannot place rest at min #{target_min} — only one set generated, adjust reps per set"
  end

  def cannot_place_rest_out_of_tolerance_even(target_min, nearest_min, diff_sec) do
    "cannot place rest at min #{target_min} — nearest rep boundary is at " <>
      "min #{nearest_min} (#{diff_sec}s away, max #{@placement_tolerance_sec}s). " <>
      "Adjust your rep count or pace."
  end

  def cannot_place_rest_out_of_tolerance_unbroken(target_min, nearest_min, diff_sec) do
    "cannot place rest at min #{target_min} — nearest set boundary is at " <>
      "min #{nearest_min} (#{diff_sec}s away, max #{@placement_tolerance_sec}s). " <>
      "Adjust your reps per set."
  end
end
