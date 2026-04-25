// Audio cues + screen-wake lock for the session runner.
//
// Server events:
//   burpee:timeline   — new timeline event. Plays rep beep (work) or
//                       lead beep (rest).
//   burpee:audio_stop — cancel any scheduled beeps (pause).
//   burpee:completed  — play the end-of-session fanfare.
//
// The Web Audio context is lazily created on first tap so the browser's
// autoplay policy is satisfied by the user-initiated Start click.
//
// Screen Wake Lock is acquired on the first timeline event and re-acquired
// when the tab becomes visible again after being backgrounded.
const BurpeeHook = {
  mounted() {
    this.ctx = null
    this.bus = null
    this.scheduledOscs = []
    this.wakeLock = null

    this.onVisibility = () => this.maybeReacquireWakeLock()
    document.addEventListener("visibilitychange", this.onVisibility)

    this.primeAudio = () => this.ensureRunningAudio()
    document.addEventListener("click", this.primeAudio, { capture: true })
    document.addEventListener("touchstart", this.primeAudio, {
      capture: true,
      passive: true
    })

    this.handleEvent("burpee:timeline", (e) => this.onTimeline(e))
    this.handleEvent("burpee:lifecycle", (e) => this.onLifecycle(e))
    this.handleEvent("burpee:tick", (e) => this.onTick(e))
    this.handleEvent("burpee:audio_stop", () => this.stopAudio())
    this.handleEvent("burpee:completed", () => this.onCompleted())
  },

  destroyed() {
    this.stopAudio()
    document.removeEventListener("visibilitychange", this.onVisibility)
    document.removeEventListener("click", this.primeAudio, { capture: true })
    document.removeEventListener("touchstart", this.primeAudio, {
      capture: true
    })
    this.releaseWakeLock()
    if (this.ctx) this.ctx.close()
  },

  // ---------------- AUDIO CORE ----------------

  audioContext() {
    if (!this.ctx) {
      const AC = window.AudioContext || window.webkitAudioContext
      this.ctx = new AC()
    }
    return this.ctx
  },

  ensureRunningAudio() {
    const ctx = this.audioContext()
    if (ctx.state === "suspended") ctx.resume().catch(() => {})
  },

  masterBus() {
    const ctx = this.audioContext()
    if (!this.bus) {
      this.bus = ctx.createGain()
      this.bus.gain.value = 1.0
      this.bus.connect(ctx.destination)
    }
    return this.bus
  },

  // ---------------- TIMELINE ----------------

  onTimeline(event) {
    this.ensureRunningAudio()
    this.acquireWakeLock()

    const ctx = this.audioContext()
    const t = ctx.currentTime + 0.05

    if (event.type === "work_burpee" || event.type === "warmup_burpee") {
      this.repBeepAt(t)
    }
    if (event.type === "work_rest" || event.type === "warmup_rest") {
      this.leadBeepAt(t)
    }
  },

  onLifecycle(_event) {},
  onTick(_event) {},

  // ---------------- SOUND PRIMITIVES ----------------

  tickAt(startAt, { freq, durMs, gain, type = "sine", attackMs = 3 }) {
    const ctx = this.audioContext()
    const dur = durMs / 1000

    const osc = ctx.createOscillator()
    const g = ctx.createGain()

    osc.type = type
    osc.frequency.setValueAtTime(freq, startAt)
    g.gain.setValueAtTime(0, startAt)
    g.gain.linearRampToValueAtTime(gain, startAt + attackMs / 1000)
    g.gain.exponentialRampToValueAtTime(0.0001, startAt + dur)

    osc.connect(g)
    g.connect(this.masterBus())
    osc.start(startAt)
    osc.stop(startAt + dur + 0.05)
    this.trackOsc(osc)
  },

  chimeAt(startAt, { freq, durMs = 300, gain = 0.4 }) {
    const ctx = this.audioContext()
    const dur = durMs / 1000
    const partials = [
      { m: 1, g: 1.0, d: dur },
      { m: 2, g: 0.4, d: dur * 0.7 },
      { m: 3, g: 0.2, d: dur * 0.5 }
    ]

    const master = ctx.createGain()
    master.gain.value = gain
    master.connect(this.masterBus())

    partials.forEach((p) => {
      const osc = ctx.createOscillator()
      const g = ctx.createGain()
      osc.frequency.setValueAtTime(freq * p.m, startAt)
      g.gain.setValueAtTime(0, startAt)
      g.gain.linearRampToValueAtTime(p.g, startAt + 0.005)
      g.gain.exponentialRampToValueAtTime(0.0001, startAt + p.d)
      osc.connect(g)
      g.connect(master)
      osc.start(startAt)
      osc.stop(startAt + p.d + 0.05)
      this.trackOsc(osc)
    })
  },

  leadBeepAt(t) {
    this.tickAt(t, { freq: 440, durMs: 150, gain: 0.6, type: "triangle" })
  },

  repBeepAt(t) {
    this.tickAt(t, { freq: 800, durMs: 40, gain: 0.7, type: "square", attackMs: 2 })
    this.chimeAt(t, { freq: 659.25, durMs: 350, gain: 0.8 })
    this.tickAt(t, { freq: 329.63, durMs: 200, gain: 0.4, type: "triangle" })
  },

  // ---------------- COMPLETION ----------------

  onCompleted() {
    this.stopAudio()
    const now = this.audioContext().currentTime
    this.chimeAt(now,       { freq: 523.25, durMs: 250, gain: 0.4 })
    this.chimeAt(now + 0.2, { freq: 659.25, durMs: 300, gain: 0.4 })
    this.chimeAt(now + 0.4, { freq: 783.99, durMs: 350, gain: 0.5 })
    this.chimeAt(now + 0.6, { freq: 1046.5, durMs: 900, gain: 0.5 })
  },

  // ---------------- UTIL ----------------

  trackOsc(osc) {
    this.scheduledOscs.push(osc)
    osc.addEventListener("ended", () => {
      this.scheduledOscs = this.scheduledOscs.filter((o) => o !== osc)
    })
  },

  stopAudio() {
    if (!this.ctx) return
    const now = this.ctx.currentTime
    this.scheduledOscs.forEach((osc) => { try { osc.stop(now) } catch (_) {} })
    this.scheduledOscs = []
  },

  acquireWakeLock() {
    if (this.wakeLock) return
    navigator.wakeLock?.request("screen").then((lock) => {
      this.wakeLock = lock
    }).catch(() => {})
  },

  maybeReacquireWakeLock() {
    if (document.visibilityState === "visible") {
      this.wakeLock = null
      this.acquireWakeLock()
    }
  },

  releaseWakeLock() {
    this.wakeLock?.release?.().catch(() => {})
    this.wakeLock = null
  }
}

export default BurpeeHook
