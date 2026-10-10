defmodule BurpeeTrainer.StarterWorkoutsMigrationTest do
  use ExUnit.Case, async: false
  alias BurpeeTrainer.PlanCompiler
  alias BurpeeTrainer.PlanCompiler.{ProgramHash, WorkoutDefinition}
  alias BurpeeTrainer.TestSupport.MigrationEquivalence, as: E

  @migrations Path.expand("../../priv/repo/migrations", __DIR__)

  test "adds one compiled starter per burpee type beside the single Steady 10 fallback" do
    E.with_db(fn repo ->
      Ecto.Migrator.run(repo, E.migrations(@migrations), :up, all: true, log: false)

      rows =
        repo.query!("""
        SELECT name, burpee_type, target_reps, target_duration_sec,
               definition_json, program_json, content_hash
        FROM workout_plans
        WHERE user_id IS NULL AND origin = 'built_in' AND state = 'published'
        ORDER BY name
        """).rows

      assert Enum.map(rows, &Enum.take(&1, 4)) == [
               ["Built-in Steady 10", "six_count", 10, 120],
               ["Starter Navy Seal", "navy_seal", 40, 1200],
               ["Starter Six-Count", "six_count", 100, 1200]
             ]

      for [name, _type, _reps, _duration, definition, program, hash] <- rows do
        {:ok, compiled} = definition |> Jason.decode!() |> WorkoutDefinition.new()
        {:ok, recompiled} = PlanCompiler.compile(compiled)
        assert compiled.name == name
        assert Jason.decode!(program) == ProgramHash.canonical_map(recompiled)
        assert hash == ProgramHash.hash(recompiled)
      end
    end)
  end
end
