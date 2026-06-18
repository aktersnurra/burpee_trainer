# Pose export bundle design

## Goal

Provide an Elixir export/preprocessing pipeline that moves captured pose traces out of the app database into portable dataset bundles for separate downstream repositories: the OCaml/Bonsai labelling tool and the Python/JAX HSMM+TCN training/analysis tooling. The bundle should include a relational SQLite slice for metadata and preprocessed `json.zst` files for trace streams.

This repo owns this export contract because it owns the source capture data. Downstream tools should depend on the bundle format, not on Burpee Trainer internals. This depends on the P0 pose capture schema and chunk storage existing.

## Non-goals

- Do not capture live pose data in this phase.
- Do not build the Bonsai labelling UI in this repo or phase.
- Do not train models in this repo or phase.
- Do not require TimescaleDB/Postgres.

## Command shape

Suggested Mix tasks:

```text
mix pose.export --capture-run-id 123 --out /tmp/pose-export-123/
mix pose.export --session-id 456 --out /tmp/session-456-pose/
mix pose.export --since 2026-06-01 --out /tmp/pose-export-june/
```

A future import task can consume labelled bundles:

```text
mix pose.import_labels /tmp/pose-export-123/
```

## Bundle layout

```text
pose-export-123/
  manifest.json
  dataset.sqlite3
  traces/
    capture-123-warmup.json.zst
    capture-123-main.json.zst
  labels/
    capture-123-labels.json.zst
  analysis/
    capture-123-hsmm-v1.json.zst
```

Only include `labels/` and `analysis/` files when matching data exists.

## `dataset.sqlite3`

The export DB carries the minimal relational slice needed for lookup, provenance, and round-tripping labels.

Include rows for:

- `pose_capture_runs`
- `pose_trace_chunks` metadata, not necessarily payload blobs if traces are materialized as files
- linked `workout_sessions`
- linked `workout_plans`
- existing `pose_labels`
- existing `pose_analysis_runs`
- existing `pose_reps`

Use stable source IDs:

- `source_capture_run_id`
- `source_session_id`
- `source_plan_id`
- `source_chunk_id`
- `source_label_id`

The export DB does not need to mirror every production table exactly. It should be optimized for portable dataset consumption and later import.

## `manifest.json`

The manifest should summarize bundle contents and make integrity checks cheap.

Fields:

```json
{
  "version": 1,
  "created_at": "2026-06-18T00:00:00Z",
  "source_app": "burpee_trainer",
  "captures": [
    {
      "source_capture_run_id": 123,
      "model_name": "blazepose-full",
      "model_version": "...",
      "segments": ["warmup", "main"],
      "sample_count": 18000,
      "files": [
        {
          "path": "traces/capture-123-main.json.zst",
          "segment": "main",
          "sample_count": 16000,
          "sha256": "..."
        }
      ]
    }
  ]
}
```

## Trace `json.zst` files

The app stores chunks for ingestion efficiency. The export task materializes those chunks into segment-level trace streams:

```text
traces/capture-123-warmup.json.zst
traces/capture-123-main.json.zst
```

Each file contains a normalized JSON representation suitable for Bonsai replay and Python training.

Conceptual shape:

```json
{
  "version": 1,
  "source_capture_run_id": 123,
  "segment": "main",
  "model": {
    "name": "blazepose-full",
    "version": "..."
  },
  "samples": [
    {
      "t_ms": 12345,
      "segment_t_ms": 2345,
      "landmarks": [...],
      "features": {...}
    }
  ]
}
```

The export task should:

1. read matching SQLite chunks
2. decompress payload blobs
3. normalize sample shape/version
4. split by capture and segment
5. write `json.zst` trace files
6. write manifest counts, hashes, model metadata, and source IDs
7. optionally include labels and analysis outputs as `json.zst`

## Compression

Use zstd for exported trace files because the downstream dataset shape favors compressed file transfer and Python tooling can read it easily.

The app's internal chunk codec may differ if browser/Elixir support makes another codec easier. Export is the normalization boundary: whatever the ingestion codec is, the exported files become `json.zst`.

## Labelling round trip

The separate Bonsai labeller should operate on exported bundles for v1. A later app-backed adapter can use public HTTP/API contracts, but the default path is bundle-based.

For offline labelling, labels should be written back to a bundle file such as:

```text
labels/capture-123-labels.json.zst
```

Label records must preserve source IDs and time ranges:

```json
{
  "source_capture_run_id": 123,
  "segment": "main",
  "start_ms": 10000,
  "end_ms": 13200,
  "label_type": "phase",
  "label": "descending",
  "source": "manual"
}
```

`mix pose.import_labels` uses source IDs to upsert labels into the app DB without depending on exported DB row IDs.

## Training workflow

The separate Python/JAX HSMM+TCN training repository should consume export bundles rather than app chunks directly:

```text
mix pose.export --since 2026-06-01 --out data/pose_exports/june
python train_tcn.py data/pose_exports/june
```

Likely model inputs:

- landmark trajectories over time windows
- visibility/presence/confidence channels
- derived body geometry features
- velocity features
- segment metadata

Likely labels:

- frame/window phase labels: `top_anchor`, `descending`, `bottom`, `rising`, `rest_standing`, `unknown`
- event labels: `rep_start`, `bottom`, `rep_end`
- interval tags: `bad_angle`, `occluded`, `partial_body`, `fatigue`, `bad_rep`

## Tests

- exports a single capture run into expected bundle layout
- exports multiple capture runs with manifest counts and hashes
- reconstructs trace samples from multiple chunks in order
- splits warmup and main into separate `json.zst` files
- includes linked session/plan metadata in `dataset.sqlite3`
- preserves stable source IDs
- import labels upserts by source IDs and time ranges
- export fails cleanly if chunks are missing or corrupt
