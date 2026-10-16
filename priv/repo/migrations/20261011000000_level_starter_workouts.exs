defmodule BurpeeTrainer.Repo.Migrations.LevelStarterWorkouts do
  use Ecto.Migration

  # The first starters (100 six-count, 40 navy seal) ranked level 1C, two levels above a
  # fresh user, so the chooser's default filter hid them. Published workouts are immutable,
  # so those rows are archived and level-1A starters are published under the same names.
  # Generated like 20261010000000_add_starter_workouts.exs.
  @retired_hashes [
    "5dc1cc3fb92f8547a468e9ad57c1269584753fc283615058cb0aa073958b5f58",
    "7eeecf78ee2f0c8fa1432837baffc840cce9759883161fd1a54361447b7e0da6"
  ]

  @starters [
    %{
      name: "Starter Six-Count",
      burpee_type: "six_count",
      target_reps: 40,
      target_duration_sec: 1200,
      definition_json:
        ~S|{"burpee_type":"six_count","events":[{"kind":"work","reps":5,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":142.857,"kind":"rest"},{"kind":"work","reps":5,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":142.857,"kind":"rest"},{"kind":"work","reps":5,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":142.857,"kind":"rest"},{"kind":"work","reps":5,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":142.857,"kind":"rest"},{"kind":"work","reps":5,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":142.857,"kind":"rest"},{"kind":"work","reps":5,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":142.857,"kind":"rest"},{"kind":"work","reps":5,"sec_per_burpee":5.0,"sec_per_rep":5.0},{"duration_sec":142.858,"kind":"rest"},{"kind":"work","reps":5,"sec_per_burpee":5.0,"sec_per_rep":5.0}],"name":"Starter Six-Count","pacing_style":"even","rationale":"Eight even sets of five six-count burpees across twenty minutes.","target_duration_sec":1200,"target_reps":40,"version":1}|,
      program_json:
        ~S|{"burpee_type":"six_count","events":[{"duration_sec":25.0,"kind":"work","reps":5,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":142857,"kind":"rest"},{"duration_sec":25.0,"kind":"work","reps":5,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":142857,"kind":"rest"},{"duration_sec":25.0,"kind":"work","reps":5,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":142857,"kind":"rest"},{"duration_sec":25.0,"kind":"work","reps":5,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":142857,"kind":"rest"},{"duration_sec":25.0,"kind":"work","reps":5,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":142857,"kind":"rest"},{"duration_sec":25.0,"kind":"work","reps":5,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":142857,"kind":"rest"},{"duration_sec":25.0,"kind":"work","reps":5,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000},{"duration_ms":142858,"kind":"rest"},{"duration_sec":25.0,"kind":"work","reps":5,"sec_per_burpee_us":5000000,"sec_per_rep_us":5000000}],"schema_version":3,"semantics":{"definition_hash":"eeac7352225ca6f69128e9349f71b348098f53efc9f837d16ec8bb943ea8dec1","pacing_style":"even"},"solver_version":1,"target_duration_ms":1200000,"target_reps":40}|,
      content_hash: "d7c64d61db9f51494df7f041aa7806e16c58a9ed439719f7dc32b5b3beab1287"
    },
    %{
      name: "Starter Navy Seal",
      burpee_type: "navy_seal",
      target_reps: 15,
      target_duration_sec: 1200,
      definition_json:
        ~S|{"burpee_type":"navy_seal","events":[{"kind":"work","reps":3,"sec_per_burpee":8.0,"sec_per_rep":8.0},{"duration_sec":270.0,"kind":"rest"},{"kind":"work","reps":3,"sec_per_burpee":8.0,"sec_per_rep":8.0},{"duration_sec":270.0,"kind":"rest"},{"kind":"work","reps":3,"sec_per_burpee":8.0,"sec_per_rep":8.0},{"duration_sec":270.0,"kind":"rest"},{"kind":"work","reps":3,"sec_per_burpee":8.0,"sec_per_rep":8.0},{"duration_sec":270.0,"kind":"rest"},{"kind":"work","reps":3,"sec_per_burpee":8.0,"sec_per_rep":8.0}],"name":"Starter Navy Seal","pacing_style":"even","rationale":"Five even sets of three navy seals across twenty minutes.","target_duration_sec":1200,"target_reps":15,"version":1}|,
      program_json:
        ~S|{"burpee_type":"navy_seal","events":[{"duration_sec":24.0,"kind":"work","reps":3,"sec_per_burpee_us":8000000,"sec_per_rep_us":8000000},{"duration_ms":270000,"kind":"rest"},{"duration_sec":24.0,"kind":"work","reps":3,"sec_per_burpee_us":8000000,"sec_per_rep_us":8000000},{"duration_ms":270000,"kind":"rest"},{"duration_sec":24.0,"kind":"work","reps":3,"sec_per_burpee_us":8000000,"sec_per_rep_us":8000000},{"duration_ms":270000,"kind":"rest"},{"duration_sec":24.0,"kind":"work","reps":3,"sec_per_burpee_us":8000000,"sec_per_rep_us":8000000},{"duration_ms":270000,"kind":"rest"},{"duration_sec":24.0,"kind":"work","reps":3,"sec_per_burpee_us":8000000,"sec_per_rep_us":8000000}],"schema_version":3,"semantics":{"definition_hash":"b77cd6c19bf928ea30501f39bd80eaf2d000eaf96cad8f46299bcb9f128592ef","pacing_style":"even"},"solver_version":1,"target_duration_ms":1200000,"target_reps":15}|,
      content_hash: "28aad2f964c418d2c60738c9ef80b7bb4d6d3a0315a4a70ae618c37cb6136fb6"
    }
  ]

  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    repo().query!(
      """
      UPDATE workout_plans SET state = 'archived', archived_at = ?1, updated_at = ?1
      WHERE user_id IS NULL AND origin = 'built_in' AND state = 'published'
        AND content_hash IN (?2, ?3)
      """,
      [now | @retired_hashes]
    )

    Enum.each(@starters, &insert_starter!(&1, now))
  end

  # Published and archived workouts can be neither deleted nor republished, so rolling back
  # leaves both generations in place.
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
      WHERE NOT EXISTS (
        SELECT 1 FROM workout_plans
        WHERE user_id IS NULL AND name = ?1 AND state = 'published'
      )
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
