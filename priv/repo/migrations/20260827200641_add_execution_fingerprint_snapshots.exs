defmodule BurpeeTrainer.Repo.Migrations.AddExecutionFingerprintSnapshots do
  use Ecto.Migration

  @snapshot_version 1
  @plan_lanes ~w[ordinary_plan coach_recommendation coach_draft prepared_workout]
  @video_lanes ~w[manual_video prepared_video]

  def up do
    alter table(:workout_sessions) do
      add :execution_fingerprint_version, :integer
      add :execution_fingerprint_snapshot, :map
    end

    flush()
    backfill_execution_snapshots()
    replace_provenance_triggers(:up)
    create_execution_snapshot_triggers()
  end

  def down do
    drop_execution_snapshot_triggers()
    drop_provenance_triggers()
    drop_context_triggers()

    alter table(:workout_sessions) do
      remove :execution_fingerprint_snapshot
      remove :execution_fingerprint_version
    end

    flush()
    create_context_triggers()
    create_predecessor_provenance_triggers()
  end

  defp backfill_execution_snapshots do
    rows =
      repo().query!("""
      SELECT ws.id, ws.authorization_lane, ws.burpee_type, ep.program_json, wv.format
      FROM workout_sessions AS ws
      LEFT JOIN execution_programs AS ep ON ep.id = ws.execution_program_id
      LEFT JOIN workout_videos AS wv ON wv.id = ws.workout_video_id
      WHERE ws.authorization_lane IS NOT NULL
      ORDER BY ws.id
      """).rows

    Enum.each(rows, fn [id, lane, burpee_type, program_json, video_format] ->
      case normalized_snapshot(lane, burpee_type, program_json, video_format) do
        {:ok, snapshot} ->
          repo().query!(
            "UPDATE workout_sessions SET execution_fingerprint_version = ?, execution_fingerprint_snapshot = json(?) WHERE id = ?",
            [@snapshot_version, Jason.encode!(snapshot), id]
          )

        :error ->
          :ok
      end
    end)
  end

  defp normalized_snapshot(lane, burpee_type, program_json, _video_format)
       when lane in @plan_lanes and burpee_type in ["six_count", "navy_seal"] and
              is_binary(program_json) do
    with {:ok, program} <- Jason.decode(program_json),
         events when is_list(events) <- map_value(program, "events"),
         true <- Enum.all?(events, &is_map/1),
         semantics when is_map(semantics) <- map_value(program, "semantics", %{}) do
      canonical_events = Enum.map(events, &canonical_event/1)
      work_events = Enum.filter(canonical_events, &match?(%{kind: :work}, &1))

      {:ok,
       %{
         "burpee_type" => burpee_type,
         "set_shape" => encode_set_shape(set_shape(work_events)),
         "recovery_pattern" => encode_recovery_pattern(recovery_pattern(canonical_events)),
         "pacing_style" => Atom.to_string(pacing_style(semantics, work_events)),
         "video_format" => "program"
       }}
    else
      _other -> :error
    end
  end

  defp normalized_snapshot(lane, burpee_type, _program_json, "follow_along")
       when lane in @video_lanes and burpee_type in ["six_count", "navy_seal"] do
    {:ok, %{"burpee_type" => burpee_type, "video_format" => "follow_along"}}
  end

  defp normalized_snapshot(_lane, _burpee_type, _program_json, _video_format), do: :error

  defp replace_provenance_triggers(:up) do
    drop_provenance_triggers()
    create_strict_provenance_triggers()
  end

  defp create_strict_provenance_triggers do
    execute("""
    CREATE TRIGGER workout_sessions_authorization_provenance_insert_trigger
    BEFORE INSERT ON workout_sessions
    FOR EACH ROW
    WHEN NOT (#{insert_lane_shape_check()})
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_authorization_lane_shape_check');
    END
    """)

    execute("""
    CREATE TRIGGER workout_sessions_authorization_provenance_update_trigger
    BEFORE UPDATE ON workout_sessions
    FOR EACH ROW
    WHEN NOT (#{update_lane_shape_check()}) OR NOT (#{authorization_immutable_check()})
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_authorization_lane_shape_check');
    END
    """)
  end

  defp create_execution_snapshot_triggers do
    execute("""
    CREATE TRIGGER workout_sessions_execution_snapshot_insert_trigger
    BEFORE INSERT ON workout_sessions
    FOR EACH ROW
    WHEN NOT (#{snapshot_insert_check()})
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_execution_snapshot_check');
    END
    """)

    execute("""
    CREATE TRIGGER workout_sessions_execution_snapshot_update_trigger
    BEFORE UPDATE ON workout_sessions
    FOR EACH ROW
    WHEN NOT (#{snapshot_update_check()})
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_execution_snapshot_immutable_check');
    END
    """)
  end

  defp drop_execution_snapshot_triggers do
    execute("DROP TRIGGER IF EXISTS workout_sessions_execution_snapshot_update_trigger")
    execute("DROP TRIGGER IF EXISTS workout_sessions_execution_snapshot_insert_trigger")
  end

  defp drop_provenance_triggers do
    execute("DROP TRIGGER IF EXISTS workout_sessions_authorization_provenance_update_trigger")
    execute("DROP TRIGGER IF EXISTS workout_sessions_authorization_provenance_insert_trigger")
  end

  defp drop_context_triggers do
    execute("DROP TRIGGER IF EXISTS workout_sessions_context_energy_update_trigger")
    execute("DROP TRIGGER IF EXISTS workout_sessions_context_energy_insert_trigger")
  end

  defp insert_lane_shape_check do
    """
    NEW.authorization_legacy = 0
    AND (
      (NEW.authorization_lane IS NULL
        AND NEW.authorization_source_id IS NULL
        AND NEW.authorization_fingerprint IS NULL
        AND NEW.plan_id IS NULL
        AND NEW.execution_program_id IS NULL
        AND NEW.prepared_workout_id IS NULL
        AND NEW.workout_video_id IS NULL)
      OR
      (NEW.authorization_lane = 'ordinary_plan'
        AND NEW.authorization_source_id IS NULL
        AND NEW.plan_id IS NOT NULL
        AND NEW.execution_program_id IS NOT NULL
        AND NEW.prepared_workout_id IS NULL
        AND NEW.workout_video_id IS NULL
        AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
      OR
      (NEW.authorization_lane IN ('coach_recommendation','coach_draft')
        AND NEW.authorization_source_id IS NOT NULL
        AND NEW.plan_id IS NOT NULL
        AND NEW.execution_program_id IS NOT NULL
        AND NEW.prepared_workout_id IS NULL
        AND NEW.workout_video_id IS NULL
        AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
      OR
      (NEW.authorization_lane = 'prepared_workout'
        AND NEW.authorization_source_id = NEW.prepared_workout_id
        AND NEW.plan_id IS NOT NULL
        AND NEW.execution_program_id IS NOT NULL
        AND NEW.workout_video_id IS NULL
        AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
      OR
      (NEW.authorization_lane = 'manual_video'
        AND NEW.authorization_source_id = NEW.workout_video_id
        AND NEW.plan_id IS NULL
        AND NEW.execution_program_id IS NULL
        AND NEW.prepared_workout_id IS NULL
        AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
      OR
      (NEW.authorization_lane = 'prepared_video'
        AND NEW.authorization_source_id = NEW.prepared_workout_id
        AND NEW.workout_video_id IS NOT NULL
        AND NEW.plan_id IS NULL
        AND NEW.execution_program_id IS NULL
        AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
    )
    """
  end

  defp update_lane_shape_check do
    """
    (NEW.authorization_legacy = 1
      AND NEW.authorization_lane IS NULL
      AND NEW.authorization_source_id IS NULL
      AND NEW.authorization_fingerprint IS NULL)
    OR (#{insert_lane_shape_check()})
    OR (
      NEW.authorization_legacy = 0
      AND NEW.authorization_lane IN ('ordinary_plan','coach_recommendation','coach_draft','prepared_workout')
      AND (NEW.plan_id IS NULL OR NEW.execution_program_id IS NULL)
      AND NEW.workout_video_id IS NULL
      AND #{valid_plan_snapshot("NEW")}
      AND (
        (NEW.authorization_lane = 'ordinary_plan'
          AND NEW.authorization_source_id IS NULL
          AND NEW.prepared_workout_id IS NULL)
        OR
        (NEW.authorization_lane IN ('coach_recommendation','coach_draft')
          AND NEW.authorization_source_id IS NOT NULL
          AND NEW.prepared_workout_id IS NULL)
        OR
        (NEW.authorization_lane = 'prepared_workout'
          AND NEW.authorization_source_id IS NOT NULL
          AND (NEW.prepared_workout_id = NEW.authorization_source_id OR NEW.prepared_workout_id IS NULL))
      )
      AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
    OR (
      NEW.authorization_legacy = 0
      AND NEW.authorization_lane = 'manual_video'
      AND NEW.authorization_source_id IS NOT NULL
      AND NEW.workout_video_id IS NULL
      AND NEW.plan_id IS NULL
      AND NEW.execution_program_id IS NULL
      AND NEW.prepared_workout_id IS NULL
      AND NEW.execution_fingerprint_version = 1
      AND json_extract(NEW.execution_fingerprint_snapshot, '$.video_format') = 'follow_along'
      AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
    OR (
      NEW.authorization_legacy = 0
      AND NEW.authorization_lane = 'prepared_video'
      AND NEW.authorization_source_id IS NOT NULL
      AND (NEW.prepared_workout_id = NEW.authorization_source_id OR NEW.prepared_workout_id IS NULL)
      AND NEW.workout_video_id IS NULL
      AND NEW.plan_id IS NULL
      AND NEW.execution_program_id IS NULL
      AND NEW.execution_fingerprint_version = 1
      AND json_extract(NEW.execution_fingerprint_snapshot, '$.video_format') = 'follow_along'
      AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
    """
  end

  defp authorization_immutable_check do
    """
    COALESCE(NEW.authorization_legacy, 0) = COALESCE(OLD.authorization_legacy, 0)
    AND COALESCE(NEW.authorization_lane, '') = COALESCE(OLD.authorization_lane, '')
    AND COALESCE(NEW.authorization_source_id, -1) = COALESCE(OLD.authorization_source_id, -1)
    AND COALESCE(NEW.authorization_fingerprint, '') = COALESCE(OLD.authorization_fingerprint, '')
    AND (NEW.plan_id IS OLD.plan_id OR (OLD.plan_id IS NOT NULL AND NEW.plan_id IS NULL))
    AND (NEW.execution_program_id IS OLD.execution_program_id OR (OLD.execution_program_id IS NOT NULL AND NEW.execution_program_id IS NULL))
    AND (NEW.prepared_workout_id IS OLD.prepared_workout_id OR (OLD.prepared_workout_id IS NOT NULL AND NEW.prepared_workout_id IS NULL))
    AND (NEW.workout_video_id IS OLD.workout_video_id OR (OLD.workout_video_id IS NOT NULL AND NEW.workout_video_id IS NULL))
    """
  end

  defp snapshot_insert_check do
    """
    (NEW.authorization_lane IS NULL
      AND NEW.execution_fingerprint_version IS NULL
      AND NEW.execution_fingerprint_snapshot IS NULL)
    OR (NEW.authorization_lane IN ('ordinary_plan','coach_recommendation','coach_draft','prepared_workout')
      AND #{valid_plan_snapshot("NEW")})
    OR (NEW.authorization_lane IN ('manual_video','prepared_video')
      AND #{valid_video_snapshot("NEW")})
    """
  end

  defp snapshot_update_check do
    """
    (
      NEW.execution_fingerprint_version IS OLD.execution_fingerprint_version
      AND NEW.execution_fingerprint_snapshot IS OLD.execution_fingerprint_snapshot
    )
    AND (
      (OLD.execution_fingerprint_version IS NULL AND OLD.execution_fingerprint_snapshot IS NULL)
      OR (NEW.authorization_lane IN ('ordinary_plan','coach_recommendation','coach_draft','prepared_workout')
        AND #{valid_plan_snapshot("NEW")})
      OR (NEW.authorization_lane IN ('manual_video','prepared_video')
        AND #{valid_video_snapshot("NEW")})
    )
    """
  end

  defp valid_plan_snapshot(row) do
    """
    #{row}.execution_fingerprint_version = 1
    AND json_valid(#{row}.execution_fingerprint_snapshot)
    AND json_extract(#{row}.execution_fingerprint_snapshot, '$.burpee_type') = #{row}.burpee_type
    AND json_extract(#{row}.execution_fingerprint_snapshot, '$.video_format') = 'program'
    AND json_type(#{row}.execution_fingerprint_snapshot, '$.set_shape') = 'object'
    AND json_type(#{row}.execution_fingerprint_snapshot, '$.recovery_pattern') = 'object'
    AND json_extract(#{row}.execution_fingerprint_snapshot, '$.pacing_style') IN ('even','unbroken')
    """
  end

  defp valid_video_snapshot(row) do
    """
    #{row}.execution_fingerprint_version = 1
    AND json_valid(#{row}.execution_fingerprint_snapshot)
    AND json_extract(#{row}.execution_fingerprint_snapshot, '$.burpee_type') = #{row}.burpee_type
    AND json_extract(#{row}.execution_fingerprint_snapshot, '$.video_format') = 'follow_along'
    """
  end

  defp create_predecessor_provenance_triggers do
    execute("""
    CREATE TRIGGER workout_sessions_authorization_provenance_insert_trigger
    BEFORE INSERT ON workout_sessions
    FOR EACH ROW
    WHEN NOT (#{predecessor_insert_check()})
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_authorization_provenance_check');
    END
    """)

    execute("""
    CREATE TRIGGER workout_sessions_authorization_provenance_update_trigger
    BEFORE UPDATE ON workout_sessions
    FOR EACH ROW
    WHEN NOT (#{predecessor_update_check()}) OR NOT (#{predecessor_immutable_check()})
    BEGIN
      SELECT RAISE(ABORT, 'workout_sessions_authorization_provenance_check');
    END
    """)
  end

  defp predecessor_insert_check do
    """
    NEW.authorization_legacy = 0
    AND (
      (NEW.authorization_lane IS NULL
        AND NEW.authorization_source_id IS NULL
        AND NEW.authorization_fingerprint IS NULL
        AND NEW.plan_id IS NULL
        AND NEW.prepared_workout_id IS NULL)
      OR
      (NEW.authorization_lane = 'ordinary_plan'
        AND NEW.authorization_source_id IS NULL
        AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
      OR
      (NEW.authorization_lane IN ('coach_recommendation','coach_draft','prepared_workout')
        AND NEW.authorization_source_id IS NOT NULL
        AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
      OR
      (NEW.authorization_lane = 'manual_video'
        AND NEW.authorization_source_id = NEW.workout_video_id
        AND NEW.plan_id IS NULL
        AND NEW.prepared_workout_id IS NULL
        AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
      OR
      (NEW.authorization_lane = 'prepared_video'
        AND NEW.authorization_source_id = NEW.prepared_workout_id
        AND NEW.workout_video_id IS NOT NULL
        AND NEW.plan_id IS NULL
        AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> '')
    )
    """
  end

  defp predecessor_update_check do
    """
    (NEW.authorization_legacy = 1
      AND NEW.authorization_lane IS NULL
      AND NEW.authorization_source_id IS NULL
      AND NEW.authorization_fingerprint IS NULL)
    OR (#{predecessor_insert_check()})
    OR (
      NEW.authorization_legacy = 0
      AND OLD.workout_video_id IS NOT NULL
      AND NEW.workout_video_id IS NULL
      AND NEW.plan_id IS NULL
      AND TRIM(COALESCE(NEW.authorization_fingerprint, '')) <> ''
      AND (
        (NEW.authorization_lane = 'manual_video'
          AND NEW.authorization_source_id = OLD.workout_video_id
          AND NEW.prepared_workout_id IS NULL)
        OR
        (NEW.authorization_lane = 'prepared_video'
          AND NEW.authorization_source_id IS NOT NULL)
      )
    )
    """
  end

  defp predecessor_immutable_check do
    """
    COALESCE(NEW.authorization_legacy, 0) = COALESCE(OLD.authorization_legacy, 0)
    AND COALESCE(NEW.authorization_lane, '') = COALESCE(OLD.authorization_lane, '')
    AND COALESCE(NEW.authorization_source_id, -1) = COALESCE(OLD.authorization_source_id, -1)
    AND COALESCE(NEW.authorization_fingerprint, '') = COALESCE(OLD.authorization_fingerprint, '')
    AND (
      NEW.workout_video_id IS OLD.workout_video_id
      OR (OLD.workout_video_id IS NOT NULL AND NEW.workout_video_id IS NULL)
    )
    """
  end

  defp create_context_triggers do
    for operation <- ["INSERT", "UPDATE"] do
      name = String.downcase(operation)

      execute("""
      CREATE TRIGGER workout_sessions_context_energy_#{name}_trigger
      BEFORE #{operation} ON workout_sessions
      FOR EACH ROW
      WHEN NOT (COALESCE(NEW.context_low_energy, 0) = 0 OR COALESCE(NEW.context_high_energy, 0) = 0)
      BEGIN
        SELECT RAISE(ABORT, 'workout_sessions_context_energy_check');
      END
      """)
    end
  end

  defp canonical_event(event) do
    case map_value(event, "kind") do
      "work" ->
        %{
          kind: :work,
          reps: map_value(event, "reps", 0),
          sec_per_rep: us_to_sec(map_value(event, "sec_per_rep_us", 0)),
          sec_per_burpee: us_to_sec(map_value(event, "sec_per_burpee_us", 0))
        }

      "rest" ->
        %{kind: :rest, duration_sec: ms_to_sec(map_value(event, "duration_ms", 0))}

      _other ->
        %{kind: :unknown}
    end
  end

  defp set_shape([]), do: :none
  defp set_shape([%{reps: reps}]), do: {:single, reps}

  defp set_shape(work_events) do
    reps = Enum.map(work_events, & &1.reps)
    if length(Enum.uniq(reps)) == 1, do: {:uniform, hd(reps)}, else: {:sequence, reps}
  end

  defp recovery_pattern(events) do
    windows =
      events
      |> Enum.reduce([], fn
        %{kind: :work}, acc ->
          [0 | acc]

        %{kind: :rest, duration_sec: duration_sec}, [current | rest] ->
          [current + duration_sec | rest]

        _other, acc ->
          acc
      end)
      |> Enum.reverse()

    cond do
      windows == [] -> :none
      Enum.all?(windows, &(&1 == 0)) -> :none
      length(Enum.uniq(windows)) == 1 -> {:uniform, hd(windows)}
      true -> {:sequence, windows}
    end
  end

  defp pacing_style(semantics, work_events) do
    case map_value(semantics, "pacing_style") do
      "even" ->
        :even

      "unbroken" ->
        :unbroken

      _other ->
        if Enum.any?(work_events, &(&1.sec_per_rep > &1.sec_per_burpee)),
          do: :even,
          else: :unbroken
    end
  end

  defp encode_set_shape(:none), do: %{"kind" => "none", "reps" => []}
  defp encode_set_shape({kind, reps}), do: %{"kind" => Atom.to_string(kind), "reps" => reps}

  defp encode_recovery_pattern(:none), do: %{"kind" => "none", "seconds" => []}

  defp encode_recovery_pattern({kind, seconds}),
    do: %{"kind" => Atom.to_string(kind), "seconds" => seconds}

  defp map_value(map, key, default \\ nil), do: Map.get(map, key, default)
  defp us_to_sec(value) when is_integer(value), do: value / 1_000_000
  defp us_to_sec(_value), do: 0.0
  defp ms_to_sec(value) when is_integer(value), do: div(value, 1_000)
  defp ms_to_sec(_value), do: 0
end
