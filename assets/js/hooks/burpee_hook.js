// Audio cues + screen-wake lock for the session runner.
//
// Server events:
//   burpee:event_changed  — new timeline event (or preroll countdown)
//                           began. For rest/countdown events, schedules
//                           two short "warning" beeps at -2s and -1s so
//                           the rep-1 beep of the next work event forms
//                           a tight 3-beep countdown (-2, -1, 0). For
//                           work events, one beep at the start of every
//                           rep inside the remaining time.
//   burpee:audio_stop     — cancel any scheduled beeps (pause).
//   burpee:completed      — play the end-of-session fanfare.
//
// The Web Audio context is lazily created on first beep so the browser's
// autoplay policy is satisfied by the user-initiated Start click.
//
// Screen Wake Lock is acquired on the first event and kept for the
// lifetime of the mount; the browser re-drops it when the tab is
// backgrounded, so we also re-acquire on visibilitychange.
const BurpeeHook = {
  mounted() {
    this.ctx = null
    this.timeouts = []
    this.wakeLock = null
    this.onVisibility = () => this.maybeReacquireWakeLock()
    document.addEventListener("visibilitychange", this.onVisibility)

    // Pre-warm the AudioContext on any click so that the first beep
    // (scheduled 3s later) fires from a "running" context. Browsers
    // only grant a running AC when it was created during a recent
    // user gesture — waiting until the first leadBeep is too late.
    this.primeAudio = () => this.ensureRunningAudio()
    document.addEventListener("click", this.primeAudio, {capture: true})
    document.addEventListener("touchstart", this.primeAudio, {capture: true, passive: true})

    this.handleEvent("burpee:event_changed", (data) => this.onEventChanged(data))
    this.handleEvent("burpee:audio_stop", () => this.stopAudio())
    this.handleEvent("burpee:completed", () => this.onCompleted())
  },

  destroyed() {
    this.stopAudio()
    document.removeEventListener("visibilitychange", this.onVisibility)
    document.removeEventListener("click", this.primeAudio, {capture: true})
    document.removeEventListener("touchstart", this.primeAudio, {capture: true})
    this.releaseWakeLock()
    if (this.ctx) this.ctx.close()
  },

  audioContext() {
    if (!this.ctx) {
      const AC = window.AudioContext || window.webkitAudioContext
      this.ctx = new AC()
    }
    return this.ctx
  },

  // Create/resume the AudioContext. Safe to call on every click;
  // browsers are idempotent about resuming an already-running context.
  ensureRunningAudio() {
    const ctx = this.audioContext()
    if (ctx.state === "suspended") {
      ctx.resume().catch(() => {})
    }
  },

  // Shared master gain keeps peaks tame when partials stack.
  masterBus() {
    const ctx = this.audioContext()
    if (!this.bus) {
      this.bus = ctx.createGain()
      this.bus.gain.value = 1.0
      this.bus.connect(ctx.destination)
    }
    return this.bus
  },

  // Single-partial tonal hit. Sine-only by default for a clean,
  // mid-forward sound that cuts through without harshness.
  //
  // The 10ms lookahead (start + 0.01) guards against the audio thread
  // picking up the schedule a sample or two late — if `now` is already
  // in the past by the time hardware processes it, the attack transient
  // can be clipped or swallowed. Most noticeable on the first beep of a
  // set, where the main thread is also running the LiveView render.
  tick({freq, durMs, gain, type = "sine", attackMs = 3, sweepTo = null}) {
    const ctx = this.audioContext()
    const bus = this.masterBus()
    const startAt = ctx.currentTime + 0.01
    const dur = durMs / 1000

    const osc = ctx.createOscillator()
    osc.type = type
    osc.frequency.setValueAtTime(freq, startAt)
    if (sweepTo) osc.frequency.exponentialRampToValueAtTime(sweepTo, startAt + dur)

    const g = ctx.createGain()
    g.gain.setValueAtTime(0, startAt)
    g.gain.linearRampToValueAtTime(gain, startAt + attackMs / 1000)
    g.gain.exponentialRampToValueAtTime(0.0001, startAt + dur)

    osc.connect(g)
    g.connect(bus)
    osc.start(startAt)
    osc.stop(startAt + dur + 0.02)
  },

  // Bell/chime via additive synthesis. Fundamental + harmonic partials
  // with staggered decay = shimmering, musical "ding" — the signature
  // sound of premium HIIT apps (Seven, Centr, Apple workout). Each
  // partial has its own envelope so higher harmonics fade first,
  // producing a natural bell-like decay tail.
  chime({freq, durMs = 350, gain = 0.45}) {
    const ctx = this.audioContext()
    const bus = this.masterBus()
    const startAt = ctx.currentTime + 0.01
    const dur = durMs / 1000

    const partials = [
      {mult: 1.0, level: 1.0,  decay: dur},
      {mult: 2.0, level: 0.45, decay: dur * 0.75},
      {mult: 3.0, level: 0.22, decay: dur * 0.55},
      {mult: 4.16, level: 0.12, decay: dur * 0.35}
    ]

    const master = ctx.createGain()
    master.gain.value = gain
    master.connect(bus)

    partials.forEach(({mult, level, decay}) => {
      const osc = ctx.createOscillator()
      osc.type = "sine"
      osc.frequency.setValueAtTime(freq * mult, startAt)

      const g = ctx.createGain()
      g.gain.setValueAtTime(0, startAt)
      g.gain.linearRampToValueAtTime(level, startAt + 0.003)
      g.gain.exponentialRampToValueAtTime(0.0001, startAt + decay)

      osc.connect(g)
      g.connect(master)
      osc.start(startAt)
      osc.stop(startAt + decay + 0.02)
    })
  },

  // Countdown tick (-2s / -1s). Warm triangle at A5 — slightly brighter
  // than a sine so it carries, but still soft enough to feel like a
  // metronome, not an alarm.
  leadBeep() {
    this.tick({freq: 880, durMs: 100, gain: 0.55, type: "triangle"})
  },

  // Rep beep — the GO tone. Built in three layers so it cuts through
  // on phone speakers during heavy breathing:
  //   1. High sine "ping" at 3.2 kHz — percussive attack transient,
  //      the brightness that makes the beep pop out.
  //   2. Bell chime at E6 (1318.5 Hz) — tonal identity, 4 partials
  //      with staggered decay for a shimmering "ding".
  //   3. Triangle reinforcement at E5 — body and weight so it's not
  //      all high-end zing.
  // Lead A5 → rep E6 is a perfect fifth — the handoff sounds musical.
  repBeep() {
    this.tick({freq: 3200, durMs: 25, gain: 0.55, type: "sine", attackMs: 1})
    this.chime({freq: 1318.5, durMs: 320, gain: 0.75})
    this.tick({freq: 659.25, durMs: 180, gain: 0.35, type: "triangle"})
  },

  schedule(delayMs, fn) {
    this.timeouts.push(setTimeout(fn, delayMs))
  },

  stopAudio() {
    this.timeouts.forEach(clearTimeout)
    this.timeouts = []
  },

  onEventChanged(data) {
    this.stopAudio()
    this.ensureRunningAudio()
    this.requestWakeLock()

    const {type, remaining_sec, sec_per_rep, burpee_count} = data

    const isLeadIn =
      type === "work_rest" ||
      type === "warmup_rest" ||
      type === "shave_rest" ||
      type === "countdown"

    const isWork = type === "work_burpee" || type === "warmup_burpee"

    if (isLeadIn) {
      // -2s and -1s countdown beeps. The rep-1 "GO" beep is fired by
      // the subsequent work event_changed handler below.
      ;[2, 1].forEach((offset) => {
        const delayMs = Math.max((remaining_sec - offset) * 1000, 0)
        this.schedule(delayMs, () => this.leadBeep())
      })
    } else if (isWork && sec_per_rep && sec_per_rep > 0 && burpee_count > 0) {
      const duration = burpee_count * sec_per_rep
      const elapsed = duration - remaining_sec
      const partial = elapsed % sec_per_rep
      const firstDelaySec = partial === 0 ? 0 : sec_per_rep - partial

      let t = firstDelaySec
      if (t === 0) {
        this.repBeep()
        t = sec_per_rep
      }

      for (; t < remaining_sec; t += sec_per_rep) {
        this.schedule(t * 1000, () => this.repBeep())
      }
    }
  },

  onCompleted() {
    this.stopAudio()
    this.releaseWakeLock()
    // Ascending C major triad — C5 (523.25) → E5 (659.25) → G5 (783.99)
    // → high C6 (1046.5) sustain. Bell chimes give a "you did it"
    // resolution without sounding cheesy.
    this.chime({freq: 523.25, durMs: 280, gain: 0.45})
    this.schedule(180, () => this.chime({freq: 659.25, durMs: 300, gain: 0.45}))
    this.schedule(360, () => this.chime({freq: 783.99, durMs: 340, gain: 0.5}))
    this.schedule(560, () => this.chime({freq: 1046.5, durMs: 900, gain: 0.55}))
  },

  async requestWakeLock() {
    if (!("wakeLock" in navigator) || this.wakeLock) return

    try {
      this.wakeLock = await navigator.wakeLock.request("screen")
      this.wakeLock.addEventListener("release", () => {
        this.wakeLock = null
      })
    } catch (_err) {
      // Permission denied or unsupported — silently continue without
      // the wake lock rather than derailing the session.
    }
  },

  releaseWakeLock() {
    if (this.wakeLock) {
      this.wakeLock.release().catch(() => {})
      this.wakeLock = null
    }
  },

  maybeReacquireWakeLock() {
    if (document.visibilityState === "visible" && this.timeouts.length > 0) {
      this.requestWakeLock()
    }
  }
}

export default BurpeeHook
