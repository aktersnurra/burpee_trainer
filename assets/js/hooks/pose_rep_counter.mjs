import { initialFsmState, stepFsm } from "./pose_rep_fsm.mjs"

export function initialCounterState() {
  return { ...initialFsmState(), cadenceMs: [] }
}

export function countRep(state, sample, thresholds) {
  const { cadenceMs, ...fsmState } = state
  const result = stepFsm(fsmState, sample, thresholds)
  const nextCadence = result.rep ? [...cadenceMs, sample.tMs] : cadenceMs

  return {
    state: { ...result.state, cadenceMs: nextCadence },
    rep: result.rep
  }
}
