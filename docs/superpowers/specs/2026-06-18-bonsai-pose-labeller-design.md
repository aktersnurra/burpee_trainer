# Bonsai pose labeller design

## Goal

Build a local web labelling tool in OCaml/Bonsai for replaying captured pose traces, tagging workout intervals, correcting model predictions, and producing labels for Python training workflows.

This tool should live in a separate repository from Burpee Trainer. It should not depend on Burpee Trainer internals. Its stable integration boundary is the exported dataset bundle format: `manifest.json`, `dataset.sqlite3`, and `json.zst` trace/label files.

## Non-goals

- Do not build this UI in TypeScript/JavaScript.
- Do not place this tool inside the Phoenix/Burpee Trainer repo.
- Do not depend on Burpee Trainer application modules or database internals beyond the export bundle contract.
- Do not capture live workout data in the labeller.
- Do not train TCN models inside the browser.
- Do not require HSMM predictions to be correct before manual labelling works.

## Source-language decision

Use OCaml/Bonsai for the labelling product surface.

Allowed non-OCaml boundaries:

- small browser FFI shims for APIs Bonsai bindings do not cover cleanly
- canvas/WebGL rendering interop if needed
- fetch/file APIs if needed

Application state, labelling logic, trace navigation, and UI behavior should live in OCaml.

## Routes

The labeller should be a separate app/repo. It can run locally against exported bundles, for example:

```text
bonsai-pose-labeller --bundle /path/to/pose-export-123/
```

If app-backed mode is useful later, add it as an adapter that talks to Burpee Trainer APIs. The default design should not require Burpee Trainer to serve the labelling UI.

## Core UI capabilities

The labeller should support:

- capture list and metadata filters
- load one capture run and segment
- skeleton replay
- timeline scrubber
- playback speed control
- zoomable visible time window
- interval selection
- label create/edit/delete
- keyboard shortcuts for common labels
- HSMM/TCN prediction overlay
- manual label overlay
- unsaved-change tracking
- save labels back to Phoenix or to an export bundle

## Labelling model

Labels are independent of raw traces and analysis outputs.

Conceptual label shape:

```json
{
  "source_capture_run_id": 123,
  "segment": "main",
  "start_ms": 10000,
  "end_ms": 13200,
  "label_type": "phase",
  "label": "descending",
  "source": "manual",
  "metadata": {}
}
```

Label types:

- `phase`
- `rep`
- `quality`
- `tag`

Initial labels:

- phase: `top_anchor`, `descending`, `bottom`, `rising`, `rest_standing`, `unknown`
- rep/event: `rep_start`, `bottom`, `rep_end`, `rep`
- quality/tag: `bad_angle`, `occluded`, `partial_body`, `bad_rep`, `fatigue`

## Screen structure

### Capture index

Shows capture runs with:

- date/time
- workout/session name
- warmup/main availability
- sample counts
- model name/version
- labels present or not
- analysis outputs present or not

### Labelling workspace

Suggested layout:

```text
┌───────────────────────────────────────┐
│ capture/session metadata              │
├───────────────────────────────────────┤
│ skeleton replay canvas                │
├───────────────────────────────────────┤
│ scrubber + zoomable timeline          │
│ manual labels + prediction overlays   │
├───────────────────────────────────────┤
│ selected interval editor / shortcuts  │
└───────────────────────────────────────┘
```

The skeleton replay should be deterministic from trace samples. It does not need video frames.

## Bonsai state model

The UI is state-machine-heavy and should model states explicitly.

Important state:

- selected capture
- selected segment
- loaded trace samples
- loaded labels
- loaded prediction overlays
- playback state: stopped, playing, paused
- current playback time
- visible timeline window
- selected interval
- draft label
- unsaved changes
- save status

The OCaml `.mli` boundary for the labeller core should expose typed operations such as:

```ocaml
type capture_id
type segment = Warmup | Main
type label_type = Phase | Rep | Quality | Tag
type label

type model

type action =
  | Select_capture of capture_id
  | Select_segment of segment
  | Seek of Time_ns.Span.t
  | Start_interval of Time_ns.Span.t
  | End_interval of Time_ns.Span.t
  | Add_label of label
  | Delete_label of Label_id.t
  | Save
```

Exact types can evolve, but the implementation should keep domain transitions testable without a browser.

## Prediction overlays

The labeller should eventually display derived analysis runs:

- HSMM phase segments
- rep candidates
- confidence/diagnostics
- TCN predictions when available

Predictions are not labels. They are overlays that can be accepted, corrected, or ignored.

## Integration boundary

### Bundle-backed mode, required for v1

The labeller reads an export bundle:

```text
manifest.json
dataset.sqlite3
traces/*.json.zst
labels/*.json.zst
```

This supports offline labelling on another machine after `rsync` and keeps repo coupling low.

### App-backed mode, optional later

A later adapter may call Phoenix endpoints:

- list captures
- fetch capture metadata
- fetch segment trace
- fetch labels
- save labels

This adapter must use public HTTP/API contracts, not internal Phoenix modules or DB assumptions.

## Training relationship

The labeller creates labels for a separate Python/JAX training repository. It should not train the model itself.

Training consumes exported traces plus labels:

```text
python train_tcn.py data/pose_exports/session-...
```

The likely training progression is:

1. collect raw traces with no labels
2. manually label small representative subsets
3. train/evaluate phase or boundary models
4. run model/HSMM over older captures
5. use labeller to correct predictions
6. retrain with corrected labels

## WASM/js_of_ocaml stance

Bonsai/js_of_ocaml is the source-language decision for the UI. Do not rewrite the entire app as a Rust/WASM UI.

Compute-heavy decoder boundaries can later become swappable modules:

```text
Trace -> DecodeOptions -> DecodeResult
```

Potential implementations:

- existing JS decoder, temporarily
- OCaml/js_of_ocaml decoder
- Rust/WASM decoder
- server-side Python/Elixir analysis output

The labeller UI should not care which decoder backend produced an overlay.

## Tests

### Bonsai/domain tests

- capture index renders loaded metadata
- selecting a capture loads segment choices
- seek updates current playback time
- interval selection creates a draft label
- saving clears unsaved changes
- deleting a label updates the timeline model
- prediction overlay and manual label overlay remain distinct

### UI smoke tests

- load a capture with warmup/main traces
- replay skeleton from samples
- label a rep interval
- label a bad-angle interval
- save labels
- reload and see labels persisted

## Open implementation details

- Separate-repo packaging and local dev workflow need a small spike.
- Canvas rendering may need a thin FFI layer.
- Bundle-backed loading may need a local-file workflow depending on browser permissions.
- Keyboard shortcut set should be finalized after first manual labelling session.
