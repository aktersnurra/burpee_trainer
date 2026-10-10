defmodule BurpeeTrainer.Repo.Migrations.AddStarterWorkouts do
  use Ecto.Migration

  # Generated with Coach.RestFitter.fit/2 (equal rest weights), WorkoutDefinition.new/1 and
  # PlanCompiler.compile/1; the stored program must recompile from the stored definition.
  @starters [
    %{
      name: "Starter Six-Count",
      burpee_type: "six_count",
      target_reps: 100,
      target_duration_sec: 1200,
      definition_json:
        ~S|{"burpee_type":"six_count","events":[{"kind":"work","reps":10,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":77.777,"kind":"rest"},{"kind":"work","reps":10,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":77.777,"kind":"rest"},{"kind":"work","reps":10,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":77.777,"kind":"rest"},{"kind":"work","reps":10,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":77.777,"kind":"rest"},{"kind":"work","reps":10,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":77.777,"kind":"rest"},{"kind":"work","reps":10,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":77.777,"kind":"rest"},{"kind":"work","reps":10,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":77.777,"kind":"rest"},{"kind":"work","reps":10,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":77.777,"kind":"rest"},{"kind":"work","reps":10,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":77.784,"kind":"rest"},{"kind":"work","reps":10,"sec_per_burpee":5.0,"sec_per_rep":5.0}],"name":"Starter Six-Count","pacing_style":"even","rationale":"Ten even sets of ten six-count burpees across twenty minutes.","target_duration_sec":1200,"target_reps":100,"version":1}|,
      program_json:
        ~S|{"burpee_type":"six_count","events":[{"duration_sec":50.0,"kind":"work","reps":10,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":77777,"kind":"rest"},{"duration_sec":50.0,"kind":"work","reps":10,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":77777,"kind":"rest"},{"duration_sec":50.0,"kind":"work","reps":10,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":77777,"kind":"rest"},{"duration_sec":50.0,"kind":"work","reps":10,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":77777,"kind":"rest"},{"duration_sec":50.0,"kind":"work","reps":10,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":77777,"kind":"rest"},{"duration_sec":50.0,"kind":"work","reps":10,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":77777,"kind":"rest"},{"duration_sec":50.0,"kind":"work","reps":10,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":77777,"kind":"rest"},{"duration_sec":50.0,"kind":"work","reps":10,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":77777,"kind":"rest"},{"duration_sec":50.0,"kind":"work","reps":10,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":77784,"kind":"rest"},{"duration_sec":50.0,"kind":"work","reps":10,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000}],"schema_version":3,"semantics":{"definition_hash":"6d46a4681317ccfbdc614fde3513d3f8ebd7564c7e2e4297645b3da9d5ad31e7","pacing_style":"even"},"solver_version":1,"target_duration_ms":1200000,"target_reps":100}|,
      content_hash: "5dc1cc3fb92f8547a468e9ad57c1269584753fc283615058cb0aa073958b5f58"
    },
    %{
      name: "Starter Navy Seal",
      burpee_type: "navy_seal",
      target_reps: 40,
      target_duration_sec: 1200,
      definition_json:
        ~S|{"burpee_type":"navy_seal","events":[{"kind":"work","reps":5,"sec_per_burpee":8.0,"sec_per_rep":8.0},{"duration_sec":125.714,"kind":"rest"},{"kind":"work","reps":5,"sec_per_burpee":8.0,"sec_per_rep":8.0},{"duration_sec":125.714,"kind":"rest"},{"kind":"work","reps":5,"sec_per_burpee":8.0,"sec_per_rep":8.0},{"duration_sec":125.714,"kind":"rest"},{"kind":"work","reps":5,"sec_per_burpee":8.0,"sec_per_rep":8.0},{"duration_sec":125.714,"kind":"rest"},{"kind":"work","reps":5,"sec_per_burpee":8.0,"sec_per_rep":8.0},{"duration_sec":125.714,"kind":"rest"},{"kind":"work","reps":5,"sec_per_burpee":8.0,"sec_per_rep":8.0},{"duration_sec":125.714,"kind":"rest"},{"kind":"work","reps":5,"sec_per_burpee":8.0,"sec_per_rep":8.0},{"duration_sec":125.716,"kind":"rest"},{"kind":"work","reps":5,"sec_per_burpee":8.0,"sec_per_rep":8.0}],"name":"Starter Navy Seal","pacing_style":"even","rationale":"Eight even sets of five navy seals across twenty minutes.","target_duration_sec":1200,"target_reps":40,"version":1}|,
      program_json:
        ~S|{"burpee_type":"navy_seal","events":[{"duration_sec":40.0,"kind":"work","reps":5,"sec_per_burpee_us":8000000,"sec_per_rep_us":8000000},{"duration_ms":125714,"kind":"rest"},{"duration_sec":40.0,"kind":"work","reps":5,"sec_per_burpee_us":8000000,"sec_per_rep_us":8000000},{"duration_ms":125714,"kind":"rest"},{"duration_sec":40.0,"kind":"work","reps":5,"sec_per_burpee_us":8000000,"sec_per_rep_us":8000000},{"duration_ms":125714,"kind":"rest"},{"duration_sec":40.0,"kind":"work","reps":5,"sec_per_burpee_us":8000000,"sec_per_rep_us":8000000},{"duration_ms":125714,"kind":"rest"},{"duration_sec":40.0,"kind":"work","reps":5,"sec_per_burpee_us":8000000,"sec_per_rep_us":8000000},{"duration_ms":125714,"kind":"rest"},{"duration_sec":40.0,"kind":"work","reps":5,"sec_per_burpee_us":8000000,"sec_per_rep_us":8000000},{"duration_ms":125714,"kind":"rest"},{"duration_sec":40.0,"kind":"work","reps":5,"sec_per_burpee_us":8000000,"sec_per_rep_us":8000000},{"duration_ms":125716,"kind":"rest"},{"duration_sec":40.0,"kind":"work","reps":5,"sec_per_burpee_us":8000000,"sec_per_rep_us":8000000}],"schema_version":3,"semantics":{"definition_hash":"22612924b0eee07df97ebb0699593f1f2f754dca9837a603e935b1534947c047","pacing_style":"even"},"solver_version":1,"target_duration_ms":1200000,"target_reps":40}|,
      content_hash: "7eeecf78ee2f0c8fa1432837baffc840cce9759883161fd1a54361447b7e0da6"
    }
  ]

  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    Enum.each(@starters, &insert_starter!(&1, now))
  end

  # Published workouts cannot be deleted (workout_plans_draft_only_delete_trigger), and
  # `up` skips starters that already exist, so rolling back leaves them in place.
  def down, do: :ok

  defp insert_starter!(starter, now) do
    repo().query!(
      """
      INSERT INTO workout_plans (
        user_id, name, origin, state, request_text, definition_json,
        program_json, content_hash, burpee_type, target_reps,
        target_duration_sec, published_at, archived_at, inserted_at, updated_at
      )
      SELECT NULL, ?1, 'built_in', 'published', NULL, json(?2), json(?3), ?4, ?5, ?6, ?7,
             ?8, NULL, ?8, ?8
      WHERE NOT EXISTS (SELECT 1 FROM workout_plans WHERE user_id IS NULL AND name = ?1)
      """,
      [
        starter.name,
        starter.definition_json,
        starter.program_json,
        starter.content_hash,
        starter.burpee_type,
        starter.target_reps,
        starter.target_duration_sec,
        now
      ]
    )
  end
end
