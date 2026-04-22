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

    this.handleEvent("burpee:event_changed", (data) => this.onEventChanged(data))
    this.handleEvent("burpee:audio_stop", () => this.stopAudio())
    this.handleEvent("burpee:completed", () => this.onCompleted())
  },

  destroyed() {
    this.stopAudio()
    document.removeEventListener("visibilitychange", this.onVisibility)
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

  // Shared master gain keeps peaks tame when click + blip stack.
  masterBus() {
    const ctx = this.audioContext()
    if (!this.bus) {
      this.bus = ctx.createGain()
      this.bus.gain.value = 1.0
      this.bus.connect(ctx.destination)
    }
    return this.bus
  },

  // Short noise burst for the attack transient — this is what gives the
  // rep beep its percussive "tick" instead of a pure tone bloop.
  click() {
    const ctx = this.audioContext()
    const now = ctx.currentTime
    const osc = ctx.createOscillator()
    const gain = ctx.createGain()
    const bus = this.masterBus()

    osc.type = "sine"
    osc.frequency.setValueAtTime(2000, now)

    gain.gain.setValueAtTime(0.4, now)
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.02)

    osc.connect(gain)
    gain.connect(bus)

    osc.start(now)
    osc.stop(now + 0.025)
  },

  // Tonal body. Exponential decay + tiny attack = snappy, gym-stopwatch
  // feel. Optional exponential pitch sweep for flourish.
  blip({freq, durMs, gain = 0.5, type = "square", sweepTo = null, attackMs = 2}) {
    const ctx = this.audioContext()
    const bus = this.masterBus()
    const now = ctx.currentTime
    const durSec = durMs / 1000

    const osc = ctx.createOscillator()
    osc.type = type
    osc.frequency.setValueAtTime(freq, now)
    if (sweepTo) {
      osc.frequency.exponentialRampToValueAtTime(sweepTo, now + durSec)
    }

    const g = ctx.createGain()
    g.gain.setValueAtTime(0, now)
    g.gain.linearRampToValueAtTime(gain, now + attackMs / 1000)
    g.gain.exponentialRampToValueAtTime(0.0001, now + durSec)

    osc.connect(g)
    g.connect(bus)
    osc.start(now)
    osc.stop(now + durSec + 0.02)
  },

  // Warning beep for the -2s / -1s countdown: warm, lower pitch, no
  // click. Unobtrusive on purpose — reserves the "sharper" tone for GO.
  leadBeep() {
    this.blip({
      freq: 520,
      durMs: 120,
      gain: 0.35,
      type: "sine"
    })
  },

  // Rep beep — the GO tone. Noise click + bright square body +
  // slight downward pitch bend makes each rep feel like a hammer tick.
  // Distinct enough from leadBeep that the -2 / -1 / 0 handoff reads
  // as "warn, warn, GO" rather than three identical tones.
  repBeep() {
    const ctx = this.audioContext()
    const now = ctx.currentTime
    const bus = this.masterBus()

    // --- BODY (low-mid punch) ---
    const bodyOsc = ctx.createOscillator()
    const bodyGain = ctx.createGain()

    bodyOsc.type = "triangle"
    bodyOsc.frequency.setValueAtTime(180, now)

    bodyGain.gain.setValueAtTime(0.6, now)
    bodyGain.gain.exponentialRampToValueAtTime(0.0001, now + 0.08)

    bodyOsc.connect(bodyGain)
    bodyGain.connect(bus)

    bodyOsc.start(now)
    bodyOsc.stop(now + 0.09)

    // --- CLICK (tight attack) ---
    const clickOsc = ctx.createOscillator()
    const clickGain = ctx.createGain()

    clickOsc.type = "square"
    clickOsc.frequency.setValueAtTime(1400, now)

    clickGain.gain.setValueAtTime(0.5, now)
    clickGain.gain.exponentialRampToValueAtTime(0.0001, now + 0.03)

    clickOsc.connect(clickGain)
    clickGain.connect(bus)

    clickOsc.start(now)
    clickOsc.stop(now + 0.04)
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
    this.requestWakeLock()

    const {type, remaining_sec, sec_per_rep, burpee_count} = data

    const isLeadIn =
      type === "work_rest" ||
      type === "warmup_rest" ||
      type === "shave_rest" ||
      type === "countdown"

    const isWork = type === "work_burpee" || type === "warmup_burpee"

    if (isLeadIn) {
      // Two warning beeps at -2s and -1s. The work event's rep-1 beep
      // lands on 0s, giving a natural 3-beep countdown at the handoff.
      ;[2, 1].forEach((offset) => {
        const delayMs = Math.max((remaining_sec - offset) * 1000, 0)
        this.schedule(delayMs, () => this.leadBeep())
      })
    } else if (isWork && sec_per_rep && sec_per_rep > 0 && burpee_count > 0) {
      // One beep per rep. Handle mid-event resume by beeping at the
      // start of the NEXT rep and every sec_per_rep thereafter.
      const duration = burpee_count * sec_per_rep
      const elapsed = duration - remaining_sec
      const partial = elapsed % sec_per_rep
      const firstDelaySec = partial === 0 ? 0 : sec_per_rep - partial

      // Fire the first beep synchronously when the event starts at
      // rep 1 — setTimeout(fn, 0) sometimes gets delayed behind the
      // event-change handoff, which swallows the rep-1 tick.
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
    // Ascending triad with a final sweep — "workout done" fanfare.
    this.blip({freq: 880, durMs: 220, gain: 0.55, type: "triangle"})
    this.schedule(240, () => this.blip({freq: 1175, durMs: 220, gain: 0.55, type: "triangle"}))
    this.schedule(480, () => {
      this.click({gain: 0.22, durMs: 12, highpass: 1600})
      this.blip({freq: 1568, durMs: 480, gain: 0.65, type: "triangle", sweepTo: 2093})
    })
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
