export const DEFAULT_THRESHOLDS = Object.freeze({
  high: 0.72,
  low: 0.35,
  minConfidence: 0.5,
  refractoryMs: 1200
})

export function initialFsmState() {
  return { phase: "up", sawDown: false, lastRepTMs: null }
}

export function stepFsm(state, sample, thresholds = DEFAULT_THRESHOLDS) {
  if (sample.confidence < thresholds.minConfidence) {
    return { state, rep: false }
  }

  if (state.phase === "up" && sample.signal <= thresholds.low) {
    return { state: { ...state, phase: "down", sawDown: true }, rep: false }
  }

  if (state.phase === "down" && sample.signal >= thresholds.high) {
    const last = state.lastRepTMs
    const outsideRefractory = last == null || sample.tMs - last >= thresholds.refractoryMs
    const rep = state.sawDown && outsideRefractory

    return {
      state: {
        phase: "up",
        sawDown: false,
        lastRepTMs: rep ? sample.tMs : state.lastRepTMs
      },
      rep
    }
  }

  return { state, rep: false }
}
