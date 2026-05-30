import test from "node:test"
import assert from "node:assert/strict"
import { buildFinishPayload } from "./pose_trace.mjs"

test("builds finish payload from cadence", () => {
  assert.deepEqual(buildFinishPayload({ durationMs: 6000, cadenceMs: [2000, 4000, 6000] }), {
    reps: 3,
    duration_ms: 6000,
    cadence_ms: [2000, 4000, 6000]
  })
})

test("rejects non-monotonic cadence", () => {
  assert.throws(
    () => buildFinishPayload({ durationMs: 6000, cadenceMs: [2000, 1000] }),
    /monotonic/
  )
})

test("rejects cadence after duration", () => {
  assert.throws(
    () => buildFinishPayload({ durationMs: 5000, cadenceMs: [2000, 6000] }),
    /duration/
  )
})
