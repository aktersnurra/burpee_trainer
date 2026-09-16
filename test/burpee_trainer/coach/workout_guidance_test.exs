defmodule BurpeeTrainer.Coach.WorkoutGuidanceTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Coach.WorkoutGuidance
  alias BurpeeTrainer.Levels

  test "definition prompt explains levels and uses measured history without turning a note into guidance" do
    user = user_fixture()

    free_form_session_fixture(user, %{
      "burpee_count_actual" => 10,
      "duration_sec_actual" => 120,
      "note_post" => "private session-only note"
    })

    prompt = WorkoutGuidance.system_prompt(user, :definition)

    assert String.starts_with?(prompt, "The events array is the source of truth")
    assert prompt =~ "Construct ordered work and rest events before writing the rationale"
    assert prompt =~ "sum all preceding event durations"
    assert prompt =~ "start its rest event at that exact elapsed second"
    assert prompt =~ "A pause described only in the rationale is not a rest event"
    assert prompt =~ "level_1b"
    assert prompt =~ "#{Levels.threshold(:level_1b, :six_count)}"
    assert prompt =~ "#{Levels.threshold(:level_1b, :navy_seal)}"
    assert prompt =~ "landmarks, not workout targets"
    assert prompt =~ "active movement time per rep"
    assert prompt =~ "whole-session density includes rests"
    assert prompt =~ "4-5 seconds"
    assert prompt =~ "8 seconds"
    assert prompt =~ "Unbroken means continuous reps within each set"

    assert prompt =~
             ~r/When recovery is\s+requested, each work event is one set; place a positive rest event/s

    assert prompt =~ ~r/allocate the remaining time to between-set rest\s+events/
    assert prompt =~ "try to distribute available recovery evenly across between-set pauses"
    assert prompt =~ "Explicit recovery instructions take precedence"
    assert prompt =~ "including cadence tails"
    assert prompt =~ "keep mandatory pauses exact"
    assert prompt =~ "Use at most three decimal places for generated second values"
    assert prompt =~ "compiler's millisecond precision"
    assert prompt =~ ~r/Levels guide set size and recovery, not\s+movement-speed\s+limits/
    assert prompt =~ "rest event"
    assert prompt =~ "exactly"
    assert prompt =~ ~s("actual_reps":10)
    assert prompt =~ ~s("actual_duration_sec":120)
    refute prompt =~ "private session-only note"
  end

  test "minute recovery blocks use whole-workout balancing rather than minute-long work" do
    prompt = WorkoutGuidance.system_prompt(user_fixture(), :definition)
    assert prompt =~ "work plus ordinary recovery"
    assert prompt =~ "unless the user explicitly asks for work-only duration"
    assert prompt =~ "across the whole workout, not independently inside each phase"
    assert prompt =~ "jointly choose set counts and rep allocation across phases"
    assert prompt =~ "Explicit ordered set_reps remain hard constraints"
    assert prompt =~ "Explain any unavoidable ordinary-rest differences"
    assert prompt =~ "Report the actual compiled duration"
  end

  test "empty-history recommendation prompt uses the same coaching principles" do
    prompt = WorkoutGuidance.system_prompt(user_fixture(), :recommendation)

    assert prompt =~ "landmarks, not workout targets"
    assert prompt =~ ~s("recent_results":[])
    assert prompt =~ "select_existing"
    assert prompt =~ "try to distribute available recovery evenly across between-set pauses"
    assert prompt =~ "Explicit recovery instructions take precedence"
    assert prompt =~ "4-5 seconds"
    assert prompt =~ "create"
  end
end
