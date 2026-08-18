defmodule BurpeeTrainer.Repo.Migrations.AllowSupersededPreparedOverrideCandidates do
  use Ecto.Migration

  @disable_ddl_transaction true

  @old_selection_union """
  (
    (lifecycle = 'override_preview' AND selection_kind = 'created'
      AND workout_plan_id IS NULL
      AND execution_program_id IS NULL
      AND execution_program_hash IS NULL
      AND workout_video_id IS NULL
      AND candidate_source_json IS NOT NULL
      AND candidate_compile_policy_json IS NOT NULL
      AND candidate_compile_policy_hash IS NOT NULL
      AND candidate_program_json IS NOT NULL
      AND candidate_program_hash IS NOT NULL)
    OR
    ((selection_kind = 'existing_workout'
       OR (selection_kind = 'created' AND lifecycle <> 'override_preview'))
      AND workout_plan_id IS NOT NULL
      AND execution_program_id IS NOT NULL
      AND execution_program_hash IS NOT NULL
      AND workout_video_id IS NULL
      AND candidate_source_json IS NULL
      AND candidate_compile_policy_json IS NULL
      AND candidate_compile_policy_hash IS NULL
      AND candidate_program_json IS NULL
      AND candidate_program_hash IS NULL)
    OR
    (selection_kind = 'video'
      AND workout_video_id IS NOT NULL
      AND workout_plan_id IS NULL
      AND execution_program_id IS NULL
      AND execution_program_hash IS NULL
      AND candidate_source_json IS NULL
      AND candidate_compile_policy_json IS NULL
      AND candidate_compile_policy_hash IS NULL
      AND candidate_program_json IS NULL
      AND candidate_program_hash IS NULL)
  )
  """

  @new_selection_union """
  (
    (lifecycle IN ('override_preview','superseded') AND selection_kind = 'created'
      AND workout_plan_id IS NULL
      AND execution_program_id IS NULL
      AND execution_program_hash IS NULL
      AND workout_video_id IS NULL
      AND candidate_source_json IS NOT NULL
      AND candidate_compile_policy_json IS NOT NULL
      AND candidate_compile_policy_hash IS NOT NULL
      AND candidate_program_json IS NOT NULL
      AND candidate_program_hash IS NOT NULL)
    OR
    ((selection_kind = 'existing_workout'
       OR (selection_kind = 'created' AND lifecycle <> 'override_preview'))
      AND workout_plan_id IS NOT NULL
      AND execution_program_id IS NOT NULL
      AND execution_program_hash IS NOT NULL
      AND workout_video_id IS NULL
      AND candidate_source_json IS NULL
      AND candidate_compile_policy_json IS NULL
      AND candidate_compile_policy_hash IS NULL
      AND candidate_program_json IS NULL
      AND candidate_program_hash IS NULL)
    OR
    (selection_kind = 'video'
      AND workout_video_id IS NOT NULL
      AND workout_plan_id IS NULL
      AND execution_program_id IS NULL
      AND execution_program_hash IS NULL
      AND candidate_source_json IS NULL
      AND candidate_compile_policy_json IS NULL
      AND candidate_compile_policy_hash IS NULL
      AND candidate_program_json IS NULL
      AND candidate_program_hash IS NULL)
  )
  """

  @selection_marker ~s(CONSTRAINT "prepared_workouts_selection_union_check" CHECK ()
  @next_constraint_marker ~s(CONSTRAINT "prepared_workouts_fallback_facts_json_check")
  @rebuilt_table "prepared_workouts_override_union_rebuilt"

  def up, do: rebuild(@new_selection_union)

  def down do
    reject_superseded_candidates!()
    rebuild(@old_selection_union)
  end

  defp reject_superseded_candidates! do
    case repo().query!("""
         SELECT COUNT(*)
         FROM prepared_workouts
         WHERE lifecycle = 'superseded'
           AND selection_kind = 'created'
           AND workout_plan_id IS NULL
           AND execution_program_id IS NULL
           AND execution_program_hash IS NULL
           AND workout_video_id IS NULL
           AND candidate_source_json IS NOT NULL
           AND candidate_compile_policy_json IS NOT NULL
           AND candidate_compile_policy_hash IS NOT NULL
           AND candidate_program_json IS NOT NULL
           AND candidate_program_hash IS NOT NULL
         """).rows do
      [[0]] ->
        :ok

      [[count]] ->
        raise "cannot roll back superseded prepared override candidates while immutable candidate history exists (count=#{count})"
    end
  end

  defp rebuild(selection_union) do
    prior_sequence = prepared_workouts_sequence()
    columns = prepared_workout_columns()
    indexes = prepared_workout_index_sql()
    rebuilt_sql = rebuilt_table_sql(selection_union)
    quoted_columns = Enum.map_join(columns, ", ", &quote_identifier/1)

    repo().query!("PRAGMA foreign_keys = OFF")
    repo().query!("DROP TABLE IF EXISTS #{@rebuilt_table}")
    repo().query!(rebuilt_sql)

    repo().query!("""
    INSERT INTO #{@rebuilt_table} (#{quoted_columns})
    SELECT #{quoted_columns} FROM prepared_workouts
    """)

    repo().query!("DROP TABLE prepared_workouts")
    repo().query!("ALTER TABLE #{@rebuilt_table} RENAME TO prepared_workouts")
    Enum.each(indexes, fn sql -> repo().query!(sql) end)
    restore_prepared_workouts_sequence(prior_sequence)
    repo().query!("PRAGMA foreign_keys = ON")
    :ok
  end

  defp rebuilt_table_sql(selection_union) do
    source_sql = prepared_workouts_table_sql()

    [before_union, after_union_marker] =
      String.split(source_sql, @selection_marker, parts: 2)

    [_old_union, after_next_constraint] =
      String.split(after_union_marker, @next_constraint_marker, parts: 2)

    (before_union <>
       @selection_marker <>
       selection_union <>
       "),\n  " <>
       @next_constraint_marker <>
       after_next_constraint)
    |> then(
      &Regex.replace(
        ~r/\ACREATE TABLE\s+"?prepared_workouts"?\s*\(/,
        &1,
        "CREATE TABLE #{@rebuilt_table} ("
      )
    )
  end

  defp prepared_workouts_table_sql do
    case repo().query!(
           "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'prepared_workouts'"
         ).rows do
      [[sql]] when is_binary(sql) -> sql
      _other -> raise "prepared_workouts table is missing"
    end
  end

  defp prepared_workout_columns do
    repo().query!("PRAGMA table_info('prepared_workouts')").rows
    |> Enum.map(fn [_cid, name | _rest] -> name end)
  end

  defp prepared_workout_index_sql do
    repo().query!("""
    SELECT sql
    FROM sqlite_master
    WHERE type = 'index'
      AND tbl_name = 'prepared_workouts'
      AND sql IS NOT NULL
    ORDER BY name
    """).rows
    |> Enum.map(fn [sql] -> sql end)
  end

  defp prepared_workouts_sequence do
    case repo().query!("SELECT seq FROM sqlite_sequence WHERE name = 'prepared_workouts'").rows do
      [[sequence]] when is_integer(sequence) -> sequence
      _other -> nil
    end
  end

  defp restore_prepared_workouts_sequence(nil), do: :ok

  defp restore_prepared_workouts_sequence(prior_sequence) do
    [[current_sequence]] =
      repo().query!(
        "SELECT COALESCE(MAX(seq), 0) FROM sqlite_sequence WHERE name = 'prepared_workouts'"
      ).rows

    [[maximum_id]] =
      repo().query!("SELECT COALESCE(MAX(id), 0) FROM prepared_workouts").rows

    sequence = max(prior_sequence, max(current_sequence, maximum_id))
    repo().query!("DELETE FROM sqlite_sequence WHERE name = 'prepared_workouts'")

    repo().query!(
      "INSERT INTO sqlite_sequence (name, seq) VALUES ('prepared_workouts', ?)",
      [sequence]
    )

    :ok
  end

  defp quote_identifier(identifier) do
    ~s("#{String.replace(identifier, "\"", "\"\"")}")
  end
end
