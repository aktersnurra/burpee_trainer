export function buildFinishPayload({ durationMs, cadenceMs }) {
  if (!Number.isInteger(durationMs) || durationMs < 0) {
    throw new Error("duration must be a non-negative integer")
  }

  if (!Array.isArray(cadenceMs)) {
    throw new Error("cadence must be an array")
  }

  for (let i = 0; i < cadenceMs.length; i++) {
    const t = cadenceMs[i]
    if (!Number.isInteger(t) || t < 0) {
      throw new Error("cadence timestamps must be non-negative integers")
    }
    if (i > 0 && t < cadenceMs[i - 1]) {
      throw new Error("cadence timestamps must be monotonic")
    }
    if (t > durationMs) {
      throw new Error("cadence timestamp exceeds duration")
    }
  }

  return {
    reps: cadenceMs.length,
    duration_ms: durationMs,
    cadence_ms: [...cadenceMs]
  }
}
