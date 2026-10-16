defmodule BurpeeTrainer.Workouts.InspectionTest do
  use BurpeeTrainer.DataCase, async: false
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.Workouts.Inspection

  defp plan(events, duration) do
    reps = Enum.reduce(events, 0, &(&2 + Map.get(&1, "reps", 0)))

    workout_plan_draft_fixture(user_fixture(), %{
      definition: %{
        "version" => 1,
        "name" => "Exact inspection",
        "burpee_type" => "six_count",
        "target_reps" => reps,
        "target_duration_sec" => duration,
        "pacing_style" => "even",
        "rationale" => "Compiler fidelity test",
        "events" => events
      }
    })
  end

  defp work(active \\ 5),
    do: %{"kind" => "work", "reps" => 2, "sec_per_rep" => 5, "sec_per_burpee" => active}

  test "identical sets precede invented block grouping" do
    p = plan(List.duplicate(work(), 6), 60)
    assert [%{kind: :repeat, count: 6}] = rows = Inspection.rows(p)
    assert Inspection.flatten(rows) == p.program_json["events"]
  end

  test "terminal active duration remains exact" do
    p = plan([work(4), work(4)], 19)
    assert length(Inspection.rows(p)) == 2
    assert Enum.map(p.program_json["events"], & &1["duration_sec"]) == [10.0, 9.0]
    assert Inspection.flatten(Inspection.rows(p)) == p.program_json["events"]
  end

  test "nonadjacent matching work never merges" do
    b = Map.put(work(), "reps", 3)
    p = plan([work(), b, work()], 35)
    assert length(Inspection.rows(p)) == 3
    repeated = plan([work(), b, work(), b], 50)
    assert [%{count: 2, units: units}] = Inspection.rows(repeated)
    assert length(units) == 4
  end

  test "recovery boundaries are never made uniform" do
    for rests <- [[10, 11], [11, 10], [10, 10]] do
      events = [
        work(),
        %{"kind" => "rest", "duration_sec" => hd(rests)},
        work(),
        %{"kind" => "rest", "duration_sec" => List.last(rests)},
        work(4)
      ]

      p = plan(events, 29 + Enum.sum(rests))
      rows = Inspection.rows(p)
      assert Inspection.flatten(rows) == p.program_json["events"]
      assert List.last(rows).kind == :set
      refute Enum.any?(rows, & &1.trailing?)
      assert List.last(List.last(rows).events)["duration_sec"] == 9.0

      assert rows
             |> Inspection.flatten()
             |> Enum.filter(&(&1["kind"] == "rest"))
             |> Enum.map(& &1["duration_ms"]) == Enum.map(rests, &(&1 * 1_000))

      assert Enum.any?(rows, &(&1.kind == :repeat)) == (hd(rests) == List.last(rests))
    end
  end

  test "definition precision survives compiler rounding" do
    p = plan([work(4.0000001), work(4.0000002), work()], 30)
    [first, second, _] = p.program_json["events"]
    assert first == second
    assert length(Inspection.rows(p)) == 3
    assert Inspection.flatten(Inspection.rows(p)) == p.program_json["events"]
  end

  test "leading recovery and row identities are stable without changing stored content" do
    p = plan([%{"kind" => "rest", "duration_sec" => 1}, work(), work()], 21)
    rows = Inspection.rows(p)
    assert [%{kind: :recovery, trailing?: false}, %{kind: :repeat, count: 2}] = rows
    assert rows == Inspection.rows(p)
    assert length(Enum.uniq_by(rows, & &1.id)) == length(rows)
    revised = %{p | updated_at: DateTime.add(p.updated_at, 1, :microsecond)}
    refute Enum.map(rows, & &1.id) == Enum.map(Inspection.rows(revised), & &1.id)
    assert Inspection.flatten(rows) == p.program_json["events"]
    stored = BurpeeTrainer.Repo.get!(BurpeeTrainer.Workouts.WorkoutPlan, p.id)
    assert stored.definition_json == p.definition_json
    assert stored.program_json == p.program_json
    assert stored.content_hash == p.content_hash
  end

  test "synthetic non-persistable terminal recovery remains explicit and lossless" do
    # The authoritative compiler rejects terminal rest. This only exercises
    # the projection traversal; it is not a valid persisted workout fixture.
    p = plan([work()], 10)
    rest = %{"kind" => "rest", "duration_sec" => 10.0}

    synthetic = %{
      p
      | definition_json: Map.update!(p.definition_json, "events", &(&1 ++ [rest, rest])),
        program_json:
          Map.update!(
            p.program_json,
            "events",
            &(&1 ++
                [
                  %{"kind" => "rest", "duration_ms" => 10_000},
                  %{"kind" => "rest", "duration_ms" => 10_000}
                ])
          )
    }

    rows = Inspection.rows(synthetic)

    assert [
             %{kind: :set},
             %{kind: :recovery, trailing?: true},
             %{kind: :recovery, trailing?: true}
           ] = rows

    assert Inspection.flatten(rows) == synthetic.program_json["events"]
  end
end
