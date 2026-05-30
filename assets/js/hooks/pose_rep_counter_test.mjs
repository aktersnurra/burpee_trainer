import test from "node:test"
import assert from "node:assert/strict"
import { initialCounterState, countRep } from "./pose_rep_counter.mjs"

function run(samples) {
  let state = initialCounterState()
  const reps = []

  for (const sample of samples) {
    const result = countRep(state, sample)
    state = result.state
    if (result.rep) reps.push(sample.tMs)
  }

  return { state, reps }
}

test("clean up-down-up cycles emit one rep per cycle", () => {
  const samples = [
    { tMs: 0, signal: 0.9, confidence: 0.9 },
    { tMs: 1000, signal: 0.2, confidence: 0.9 },
    { tMs: 2500, signal: 0.9, confidence: 0.9 },
    { tMs: 4000, signal: 0.2, confidence: 0.9 },
    { tMs: 5500, signal: 0.9, confidence: 0.9 }
  ]

  const { state, reps } = run(samples)
  assert.deepEqual(reps, [2500, 5500])
  assert.deepEqual(state.cadenceMs, [2500, 5500])
})

test("noise inside hysteresis band emits zero reps", () => {
  const samples = [0, 1, 2, 3, 4].map(i => ({
    tMs: i * 500,
    signal: i % 2 === 0 ? 0.55 : 0.45,
    confidence: 0.9
  }))

  const { reps } = run(samples)
  assert.deepEqual(reps, [])
})

test("refractory suppresses double count", () => {
  const samples = [
    { tMs: 0, signal: 0.9, confidence: 0.9 },
    { tMs: 500, signal: 0.2, confidence: 0.9 },
    { tMs: 900, signal: 0.9, confidence: 0.9 },
    { tMs: 1100, signal: 0.2, confidence: 0.9 },
    { tMs: 1300, signal: 0.9, confidence: 0.9 },
    { tMs: 3000, signal: 0.2, confidence: 0.9 },
    { tMs: 4300, signal: 0.9, confidence: 0.9 }
  ]

  const { reps } = run(samples)
  assert.deepEqual(reps, [900, 4300])
})

test("low confidence samples do not transition", () => {
  const samples = [
    { tMs: 0, signal: 0.9, confidence: 0.9 },
    { tMs: 1000, signal: 0.2, confidence: 0.1 },
    { tMs: 2500, signal: 0.9, confidence: 0.9 }
  ]

  const { reps } = run(samples)
  assert.deepEqual(reps, [])
})
