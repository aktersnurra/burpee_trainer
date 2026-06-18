# Pose capture and labelling umbrella design

## Goal

Build a local-first pose data pipeline for burpee training sessions. The immediate priority is camera setup and full-body BlazePose trace collection for real workouts, including warmups. The longer-term goal is to use the collected traces as training data for robust rep, pace, phase, and fatigue analysis.

This umbrella document links three focused specs. Treat them as separate implementation tracks with clear dependencies.

## Focused specs

1. [`2026-06-18-pose-capture-p0-design.md`](./2026-06-18-pose-capture-p0-design.md)
   - P0 camera setup before tracked sessions.
   - Warmup + main pose trace collection.
   - SQLite capture-run and chunk storage.
   - Session linking and abort/failure handling.

2. [`2026-06-18-pose-export-bundles-design.md`](./2026-06-18-pose-export-bundles-design.md)
   - Export captured traces into portable dataset bundles.
   - Include `dataset.sqlite3`, `manifest.json`, and preprocessed `json.zst` trace files.
   - Preserve stable source IDs for labelling and import.
   - This repo owns the bundle contract because it owns the source data.

3. [`2026-06-18-bonsai-pose-labeller-design.md`](./2026-06-18-bonsai-pose-labeller-design.md)
   - OCaml/Bonsai labelling tool.
   - Trace replay, scrubber, interval labels, rep/phase tags, prediction overlays.
   - Lives in a separate repository and consumes this app's export bundle contract.

## Priority order

1. **P0 pose capture** — build this first. Without real traces, export and labelling have nothing useful to operate on.
2. **Export bundles** — add once traces exist so data can be moved to labelling/training machines.
3. **Bonsai labeller** — build in its own repository once bundle shape and basic trace access are stable.
4. **Offline analysis/training** — build Python/JAX HSMM+TCN tooling in its own repository after labelled data exists.

## Core decisions

- Store full raw-ish BlazePose traces, not video frames.
- Save data regardless of live rep-counter or HSMM robustness.
- Capture warmup and main workout segments.
- Keep raw traces immutable; store labels and analysis outputs separately.
- Use SQLite and compressed chunked blobs for app storage.
- Use `json.zst` preprocessing bundles for labelling and Python training.
- Build the labelling product surface in a separate OCaml/Bonsai repository, not inside this Phoenix app.
- Keep Python/JAX model-training and HSMM+TCN analysis in a separate repository.
- Consider WASM/js_of_ocaml only for compute-heavy decoder boundaries, not as a reason to delay P0 capture.
