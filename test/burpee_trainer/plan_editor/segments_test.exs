defmodule BurpeeTrainer.PlanEditor.SegmentsTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanEditor
  alias BurpeeTrainer.PlanEditor.Segments
  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.PlanSolver.Input

  defp solve!(overrides) do
    input =
      struct!(
        Input,
        Map.merge(
          %{
            name: "t",
            burpee_type: :six_count,
            target_duration_min: 20,
            burpee_count_target: 140,
            pacing_style: :unbroken,
            level: :level_2,
            reps_per_set: 8,
            additional_rests: []
          },
          overrides
        )
      )

    {:ok, solution} = PlanSolver.solve(input)
    solution
  end

  defp editor_input(overrides \\ %{}) do
    Map.merge(
      %{
        PlanEditor.default_input()
        | burpee_count_target: 140,
          pacing_style: :unbroken,
          reps_per_set: 8
      },
      overrides
    )
  end

  describe "from_solution/1" do
    test "folds materialization splits back into user-shaped segments" do
      segments = Segments.from_solution(solve!(%{}))

      assert Segments.total_reps(segments) == 140
      assert Segments.notation(segments) == "14×[8] 4×[7]"
    end

    test "keeps rest steps as rest segments" do
      segments =
        Segments.from_solution(solve!(%{additional_rests: [%{rest_sec: 30, target_min: 10}]}))

      assert Enum.any?(segments, &(&1.kind == :rest and &1.rest_sec == 30))
      assert Segments.total_reps(segments) == 140
    end
  end

  describe "balance/3" do
    test "matches targets exactly for a solver-generated structure" do
      segments = Segments.from_solution(solve!(%{}))
      balance = Segments.balance(segments, editor_input(), :level_2)

      assert balance.ok?
      assert balance.problems == []
      assert balance.reps == 140
      assert_in_delta balance.duration_sec, 1200.0, 0.001
      assert balance.recovery_sec >= 8
    end

    test "flags structures that no longer match the rep target with fixes" do
      segments = [%{kind: :work, repeat: 16, pattern: [8]}]
      balance = Segments.balance(segments, editor_input(), :level_2)

      refute balance.ok?
      assert [%{kind: :reps_mismatch, fixes: fixes}] = balance.problems
      assert Enum.any?(fixes, &(&1.kind == :reps and &1.value == 128))
      assert Enum.any?(fixes, &(&1.kind == :regenerate))
    end

    test "flags impossible duration with duration and reps fixes" do
      segments = [%{kind: :work, repeat: 40, pattern: [8]}]

      balance =
        Segments.balance(
          segments,
          editor_input(%{burpee_count_target: 320, target_duration_min: 10}),
          :level_2
        )

      refute balance.ok?
      assert problem = Enum.find(balance.problems, &(&1.kind == :no_time))
      assert Enum.any?(problem.fixes, &(&1.kind == :duration))
      assert Enum.any?(problem.fixes, &(&1.kind == :reps))
    end

    test "warns about thin recovery without blocking" do
      segments = [%{kind: :work, repeat: 46, pattern: [3]}]

      balance =
        Segments.balance(
          segments,
          editor_input(%{burpee_count_target: 138, target_duration_min: 13}),
          :level_2
        )

      assert problem = Enum.find(balance.problems, &(&1.kind == :thin_recovery))
      refute problem.blocking
    end

    test "even pacing spreads the budget into the cadence" do
      segments = [%{kind: :work, repeat: 10, pattern: [10]}]

      balance =
        Segments.balance(
          segments,
          editor_input(%{pacing_style: :even, burpee_count_target: 100}),
          :level_2
        )

      assert balance.ok?
      assert balance.recovery_sec == 0
      assert_in_delta balance.pace, 12.0, 0.001
      assert_in_delta balance.duration_sec, 1200.0, 0.001
    end
  end

  describe "editing" do
    test "update_work changes repeats and set reps" do
      segments = [%{kind: :work, repeat: 14, pattern: [8]}]

      segments = Segments.update_work(segments, 0, 10, %{0 => 7})

      assert segments == [%{kind: :work, repeat: 10, pattern: [7]}]
    end

    test "add_set and remove_set edit the pattern" do
      segments = [%{kind: :work, repeat: 5, pattern: [7]}]

      segments = Segments.add_set(segments, 0)
      assert [%{pattern: [7, 7]}] = segments

      segments = Segments.remove_set(segments, 0, 0)
      assert [%{pattern: [7]}] = segments
    end

    test "removing the last set drops the segment" do
      segments = [%{kind: :work, repeat: 5, pattern: [7]}]

      assert Segments.remove_set(segments, 0, 0) == []
    end

    test "split_work halves a repeated segment" do
      segments = [%{kind: :work, repeat: 5, pattern: [8]}]

      assert [
               %{kind: :work, repeat: 3, pattern: [8]},
               %{kind: :work, repeat: 2, pattern: [8]}
             ] = Segments.split_work(segments, 0)
    end

    test "insert_rest and insert_work place segments after the index" do
      segments = [%{kind: :work, repeat: 5, pattern: [8]}]

      segments = Segments.insert_rest(segments, 0)
      assert [%{kind: :work}, %{kind: :rest, rest_sec: 30}] = segments

      segments = Segments.insert_work(segments, 1, 8)
      assert [%{kind: :work}, %{kind: :rest}, %{kind: :work, repeat: 1, pattern: [8]}] = segments
    end
  end

  describe "to_plan_attrs/3" do
    test "round-trips through a changeset to the exact target duration" do
      input = editor_input()
      segments = Segments.from_solution(solve!(%{}))
      balance = Segments.balance(segments, input, :level_2)
      attrs = Segments.to_plan_attrs(segments, input, balance)

      plan =
        %BurpeeTrainer.Workouts.WorkoutPlan{}
        |> BurpeeTrainer.Workouts.change_plan(attrs)
        |> Ecto.Changeset.apply_changes()

      summary = BurpeeTrainer.Planner.summary(plan)
      assert summary.burpee_count_total == 140
      assert_in_delta summary.duration_sec_total, 1200.0, 1.0

      # Reading the saved structure back yields the same segments.
      assert Segments.from_plan(plan) == segments
    end

    test "manual structures with rests materialize rest steps and exact duration" do
      input = editor_input(%{burpee_count_target: 139})

      segments = [
        %{kind: :work, repeat: 9, pattern: [8]},
        %{kind: :rest, rest_sec: 45},
        %{kind: :work, repeat: 5, pattern: [7, 6]},
        %{kind: :work, repeat: 1, pattern: [2]}
      ]

      balance = Segments.balance(segments, input, :level_2)
      assert balance.ok?

      attrs = Segments.to_plan_attrs(segments, input, balance)

      plan =
        %BurpeeTrainer.Workouts.WorkoutPlan{}
        |> BurpeeTrainer.Workouts.change_plan(attrs)
        |> Ecto.Changeset.apply_changes()

      summary = BurpeeTrainer.Planner.summary(plan)
      assert summary.burpee_count_total == 139
      assert_in_delta summary.duration_sec_total, 1200.0, 1.0

      assert Enum.count(plan.steps, &(&1.kind == :rest)) == 1
      assert plan.additional_rests =~ "45"
    end
  end

  describe "timeline/2" do
    test "ends at the target duration" do
      input = editor_input()
      segments = Segments.from_solution(solve!(%{}))
      balance = Segments.balance(segments, input, :level_2)

      rows = Segments.timeline(segments, balance)
      finish = List.last(rows)

      assert finish.kind == :finish
      assert_in_delta finish.at_sec, 1200.0, 1.0
    end
  end
end
