// Audio cues for the session runner. Reacts to server events:
//
//   burpee:event_changed  — new timeline event begun. For work/warmup
//                           burpee events, plays a 3-2-1 countdown
//                           (three short beeps at 0s, 1s, 2s) before
//                           the set proper. Rest events are silent.
//   burpee:audio_stop     — cancel any scheduled beeps.
//   burpee:completed      — play the end-of-session fanfare.
//
// The Web Audio context is lazily created on first beep so the browser's
// autoplay policy is satisfied by the user-initiated Start click.
const BurpeeHook = {
  mounted() {
    this.ctx = null
    this.timeouts = []

    this.handleEvent("burpee:event_changed", (data) => this.onEventChanged(data))
    this.handleEvent("burpee:audio_stop", () => this.stopAudio())
    this.handleEvent("burpee:completed", () => this.playCompletion())
  },

  destroyed() {
    this.stopAudio()
    if (this.ctx) this.ctx.close()
  },

  audioContext() {
    if (!this.ctx) {
      const AC = window.AudioContext || window.webkitAudioContext
      this.ctx = new AC()
    }
    return this.ctx
  },

  beep(freq, durMs, gainValue = 0.2) {
    const ctx = this.audioContext()
    const osc = ctx.createOscillator()
    const gain = ctx.createGain()
    osc.type = "sine"
    osc.frequency.value = freq
    osc.connect(gain)
    gain.connect(ctx.destination)
    const now = ctx.currentTime
    gain.gain.setValueAtTime(gainValue, now)
    gain.gain.exponentialRampToValueAtTime(0.0001, now + durMs / 1000)
    osc.start(now)
    osc.stop(now + durMs / 1000)
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
    const {type} = data

    if (type === "work_burpee" || type === "warmup_burpee") {
      // 3-2-1 countdown: three short beeps at 0s, 1s, 2s.
      // Pitch rises on the final beep to signal "go".
      this.schedule(0, () => this.beep(660, 150))
      this.schedule(1000, () => this.beep(660, 150))
      this.schedule(2000, () => this.beep(880, 250))
    }
  },

  playCompletion() {
    this.beep(1046, 200)
    this.schedule(220, () => this.beep(1318, 200))
    this.schedule(450, () => this.beep(1568, 400))
  }
}

export default BurpeeHook
