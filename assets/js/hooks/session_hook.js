// SessionHook — client-driven session runtime.
//
// The server pushes a flat timeline on mount ("session_ready"). The client
// owns the clock (performance.now + requestAnimationFrame), state machine,
// beeps, and all high-frequency DOM updates. The server is idle during the
// workout and only involved at save time.
//
// Events sent TO the server:
//   warmup_requested  — user tapped Yes on warmup prompt
//   session_started   — user picked mood, session begins
//   session_complete  — workout finished; carries main + warmup counts
//
// Events received FROM the server:
//   session_ready     — initial main timeline
//   warmup_ready      — warmup timeline prepended on Yes

const SessionHook = {
  mounted() {
    this.ctx           = null
    this.bus           = null
    this.scheduledOscs = []
    this.wakeLock      = null

    this.timeline      = []
    this.mainTimeline  = []
    this.startTime     = null
    this.totalDuration = 0
    this.paused        = false
    this.pauseTime     = null
    this.rafId         = null

    this.lastRepIndex      = -1
    this.lastRestCount     = null
    this.warmupBurpeeCount = 0
    this.mainBurpeeCount   = 0
    this.warmupEndSec      = 0   // elapsed time when warmup phase ends

    this.hiddenAt = null  // track when tab went hidden for pause accounting

    this.onVisibility = () => {
      if (document.visibilityState === "hidden") {
        // Screen locked / tab backgrounded — pause the clock silently.
        if (!this.paused && this.startTime !== null) {
          this.hiddenAt = performance.now()
          if (this.rafId) cancelAnimationFrame(this.rafId)
          this.rafId = null
          this.stopAudio()
        }
      } else {
        // Tab visible again — absorb the gap into startTime so elapsed is unaffected.
        if (!this.paused && this.hiddenAt !== null && this.startTime !== null) {
          this.startTime += performance.now() - this.hiddenAt
        }
        this.hiddenAt = null
        this.maybeReacquireWakeLock()
        // Restart the RAF loop if we were running.
        if (!this.paused && this.startTime !== null && !this.rafId) {
          this.rafId = requestAnimationFrame(() => this.tick())
        }
      }
    }
    document.addEventListener("visibilitychange", this.onVisibility)

    this.primeAudio = () => this.ensureRunningAudio()
    document.addEventListener("click",      this.primeAudio, {capture: true})
    document.addEventListener("touchstart", this.primeAudio, {capture: true, passive: true})

    this.handleEvent("session_ready", ({timeline}) => {
      this.mainTimeline = timeline
      this.showWarmupPrompt()
    })

    this.handleEvent("warmup_ready", ({warmup}) => {
      this.timeline = [...warmup, ...this.mainTimeline]
      this.startCountdown()
    })

    // Event delegation on the outer hook element — survives LiveView re-renders
    // because the hook root (#burpee-session) is never replaced.
    this.el.addEventListener("click", (e) => {
      const warmupYes   = e.target.closest("#warmup-yes-btn")
      const warmupSkip  = e.target.closest("#warmup-skip-btn")
      const pauseBtn    = e.target.closest("#pause-btn")
      const finishEarly = e.target.closest("#finish-early-btn")

      if (warmupYes)   this.onWarmupYes()
      if (warmupSkip)  this.onWarmupSkip()
      if (pauseBtn)    this.togglePause()
      if (finishEarly) this.onFinishEarly()
    })
  },

  destroyed() {
    if (this.rafId) cancelAnimationFrame(this.rafId)
    this.stopAudio()
    document.removeEventListener("visibilitychange", this.onVisibility)
    document.removeEventListener("click",      this.primeAudio, {capture: true})
    document.removeEventListener("touchstart", this.primeAudio, {capture: true})
    this.releaseWakeLock()
    if (this.ctx) this.ctx.close()
  },

  // ---------------------------------------------------------------------------
  // Session flow
  // ---------------------------------------------------------------------------

  showWarmupPrompt() {
    // Overlay is already rendered by the server; nothing to do here.
  },

  onWarmupYes() {
    this.pushEvent("warmup_requested", {})
    // server responds with warmup_ready → startCountdown()
  },

  onWarmupSkip() {
    this.timeline = this.mainTimeline
    this.showMoodPicker()
  },

  showMoodPicker() {
    const overlay = this.el.querySelector("#start-overlay")
    if (!overlay) return

    // Patch the overlay in-place — delegation on the hook root catches the clicks.
    overlay.innerHTML = `
      <span class="text-xl font-semibold tracking-tight">How do you feel?</span>
      <div class="flex gap-3">
        ${[["😮‍💨","Tired","-1"],["😐","OK","0"],["💪","Hyped","1"]].map(([emoji,label,val]) => `
          <button type="button" data-mood="${val}"
            class="flex flex-col items-center gap-1.5 rounded-xl border border-[#1E2535] px-5 py-3 text-sm font-medium transition active:scale-[0.97] hover:bg-[#181C26]">
            <span class="text-2xl">${emoji}</span>
            <span>${label}</span>
          </button>
        `).join("")}
      </div>
    `

    // Delegation won't reach data-mood — wire these directly since the overlay is JS-owned.
    overlay.querySelectorAll("[data-mood]").forEach(btn => {
      btn.addEventListener("click", () => {
        const mood = btn.getAttribute("data-mood")
        this.pushEvent("session_started", {mood})
        this.startCountdown()
      })
    })
  },

  // Show a 5-4-3-2-1 countdown overlay before the workout clock begins.
  // Color ramp: 5=amber, 4=amber-orange, 3=orange, 2=orange-red, 1=red
  countdownColor(n) {
    return ["#EF4444","#F97316","#F97316","#F59E0B","#F59E0B"][n] || "#F59E0B"
  },

  startCountdown() {
    this.ensureRunningAudio()
    this.acquireWakeLock()

    const overlay = this.el.querySelector("#start-overlay")
    if (overlay) overlay.remove()

    const ring       = this.el.querySelector("#progress-ring")
    const circ       = 2 * Math.PI * 107

    // Prime ring to full instantly before the first tick so there's no flash from empty.
    if (ring) {
      ring.style.transition       = "none"
      ring.style.strokeDasharray  = circ.toFixed(4)
      ring.style.strokeDashoffset = "0"
      ring.style.stroke           = this.countdownColor(5)
    }

    const clockTop     = this.el.querySelector("#clock-top")
    const clockPrimary = this.el.querySelector("#clock-primary")
    const clockBottom  = this.el.querySelector("#clock-bottom")

    if (clockTop)    { clockTop.textContent    = "get ready" }
    if (clockBottom) { clockBottom.textContent = "" }

    const showCount = (n, animate) => {
      const color = this.countdownColor(n)

      if (clockPrimary) {
        clockPrimary.textContent = n
        clockPrimary.style.color = color
        clockPrimary.classList.remove("countdown-pop")
        void clockPrimary.offsetWidth
        clockPrimary.classList.add("countdown-pop")
      }

      if (ring) {
        const remaining = n / 5
        ring.style.transition       = animate ? "stroke-dashoffset 0.8s ease-out, stroke 0.3s" : "none"
        ring.style.strokeDasharray  = circ.toFixed(4)
        ring.style.strokeDashoffset = (circ * (1 - remaining)).toFixed(4)
        ring.style.stroke           = color
      }
    }

    // Render 5 with no transition — ring stays full, no animation flash.
    showCount(5, false)
    this.leadBeepAt(this.audioContext().currentTime + 0.02)

    let count = 4
    const tick = () => {
      if (count >= 1) {
        showCount(count, true)
        this.leadBeepAt(this.audioContext().currentTime + 0.02)
        count--
        setTimeout(tick, 1000)
      } else {
        if (clockPrimary) { clockPrimary.style.color = "" }
        if (clockTop)     { clockTop.textContent     = "" }
        this.beginSession()
      }
    }
    setTimeout(tick, 1000)
  },

  beginSession() {
    this.totalDuration = this.timeline.reduce((s, e) => s + e.duration_sec, 0)
    this.warmupEndSec  = this.timeline
      .filter(e => e.type === "warmup_burpee" || e.type === "warmup_rest")
      .reduce((s, e) => s + e.duration_sec, 0)

    // Enable pause / finish-early buttons
    const pauseBtn       = this.el.querySelector("#pause-btn")
    const finishEarlyBtn = this.el.querySelector("#finish-early-btn")
    if (pauseBtn)       pauseBtn.removeAttribute("disabled")
    if (finishEarlyBtn) finishEarlyBtn.removeAttribute("disabled")

    this.startTime = performance.now()
    this.rafId = requestAnimationFrame(() => this.tick())
  },

  // ---------------------------------------------------------------------------
  // Clock loop
  // ---------------------------------------------------------------------------

  tick() {
    const now     = performance.now()
    const elapsed = (now - this.startTime) / 1000
    const state   = this.currentEvent(elapsed)

    this.updateUI(state, elapsed)
    this.checkBeeps(state, elapsed)

    if (!this.paused && elapsed < this.totalDuration) {
      this.rafId = requestAnimationFrame(() => this.tick())
    } else if (elapsed >= this.totalDuration) {
      this.onComplete(elapsed)
    }
  },

  currentEvent(elapsed_sec) {
    let cursor = 0
    for (const event of this.timeline) {
      if (elapsed_sec < cursor + event.duration_sec) {
        return {
          event,
          phase_elapsed:   elapsed_sec - cursor,
          phase_remaining: event.duration_sec - (elapsed_sec - cursor)
        }
      }
      cursor += event.duration_sec
    }
    return null
  },

  // ---------------------------------------------------------------------------
  // Pause / resume
  // ---------------------------------------------------------------------------

  togglePause() {
    if (this.paused) {
      this.resume()
    } else {
      this.pause()
    }
  },

  pause() {
    if (this.paused) return
    this.paused    = true
    this.pauseTime = performance.now()
    if (this.rafId) cancelAnimationFrame(this.rafId)
    this.stopAudio()
    this.updatePauseBtn(true)
  },

  resume() {
    if (!this.paused) return
    this.startTime += performance.now() - this.pauseTime
    this.paused    = false
    this.hiddenAt  = null
    this.rafId     = requestAnimationFrame(() => this.tick())
    this.updatePauseBtn(false)
  },

  updatePauseBtn(paused) {
    const btn = this.el.querySelector("#pause-btn")
    if (!btn) return
    btn.innerHTML = paused
      ? `<svg viewBox="0 0 20 20" fill="currentColor" class="h-4 w-4"><path d="M6 4l10 6-10 6V4z"/></svg><span>Resume</span>`
      : `<svg viewBox="0 0 20 20" fill="currentColor" class="h-4 w-4"><rect x="5" y="4" width="3" height="12" rx="0.5"/><rect x="12" y="4" width="3" height="12" rx="0.5"/></svg><span>Pause</span>`
  },

  onFinishEarly() {
    if (!confirm("End the session now and log what you've done so far?")) return
    const elapsed = (performance.now() - this.startTime) / 1000
    this.onComplete(elapsed)
  },

  // ---------------------------------------------------------------------------
  // Beeps
  // ---------------------------------------------------------------------------

  checkBeeps(state, elapsed) {
    if (!state) return
    const {event, phase_elapsed, phase_remaining} = state

    // Rep beep: fire once per rep boundary within a burpee phase
    if (event.type === "work_burpee" || event.type === "warmup_burpee") {
      const secPerRep = event.sec_per_burpee || (event.duration_sec / (event.burpee_count || 1))
      const repIndex  = Math.floor(phase_elapsed / secPerRep)
      if (repIndex !== this.lastRepIndex) {
        this.lastRepIndex = repIndex
        this.repBeepAt(this.audioContext().currentTime + 0.02)

        // Track per-type rep counts
        if (event.type === "warmup_burpee") {
          this.warmupBurpeeCount++
        } else {
          this.mainBurpeeCount++
        }
      }
    } else {
      this.lastRepIndex = -1
    }

    // Rest-ending countdown: lead beep at 2 and 1, rep beep at 0 (first burpee of next set).
    // Safe if rest < 2s — countSec will simply never reach 2 so nothing fires early.
    const REST_TYPES = ["work_rest", "warmup_rest", "rest_block"]
    if (REST_TYPES.includes(event.type)) {
      if (phase_remaining <= 2) {
        const countSec = Math.ceil(phase_remaining)  // 2, 1, 0
        if (countSec !== this.lastRestCount) {
          this.lastRestCount = countSec
          if (countSec === 0) {
            this.repBeepAt(this.audioContext().currentTime + 0.02)
          } else {
            this.leadBeepAt(this.audioContext().currentTime + 0.02)
          }
        }
      } else {
        this.lastRestCount = null
      }
    } else {
      this.lastRestCount = null
    }
  },

  // ---------------------------------------------------------------------------
  // UI updates (direct DOM writes for high-frequency elements)
  // ---------------------------------------------------------------------------

  updateUI(state, elapsed) {
    const totalSec = this.totalDuration
    const timeLeft = Math.max(totalSec - elapsed, 0)

    // Overall progress bar — fills over the whole workout
    const overallPct = totalSec > 0 ? Math.min(elapsed / totalSec * 100, 100) : 0
    const fill = this.el.querySelector("#progress-fill")
    if (fill) fill.style.width = overallPct.toFixed(1) + "%"

    const timeLeftEl = this.el.querySelector("#time-left")
    if (timeLeftEl) timeLeftEl.textContent = this.formatTime(timeLeft)

    if (!state) return

    const {event, phase_elapsed, phase_remaining} = state
    const isWork    = event.type === "work_burpee" || event.type === "warmup_burpee"
    const isRest    = event.type === "work_rest" || event.type === "warmup_rest" || event.type === "rest_block"
    const isWarning = isRest && phase_remaining <= 5

    // Phase color (inline style — Tailwind JIT can't detect dynamic class strings)
    const color = this.phaseColor(event.type, isWarning)

    // Ring — fills based on current phase progress (not whole workout)
    const ring = this.el.querySelector("#progress-ring")
    if (ring) {
      const circ        = 2 * Math.PI * 107
      const phasePct    = event.duration_sec > 0 ? phase_elapsed / event.duration_sec : 0
      const offset      = circ * (1 - Math.min(phasePct, 1))
      ring.style.strokeDasharray  = circ.toFixed(4)
      ring.style.strokeDashoffset = offset.toFixed(4)
      ring.style.stroke           = color
      ring.style.transition       = "stroke 0.4s"
    }

    // Overall progress bar color
    if (fill) fill.style.backgroundColor = isWarning ? "#F59E0B" : color

    // Phase badge
    const badge = this.el.querySelector("#phase-badge")
    if (badge) {
      const {bg, text} = this.phaseBadgeStyle(event.type, isWarning)
      badge.textContent        = this.phaseLabel(event.type)
      badge.style.backgroundColor = bg
      badge.style.color           = text
      badge.className = "inline-flex items-center rounded-full px-2.5 py-1 text-[13px] font-medium uppercase tracking-[0.06em]"
    }

    const setLabel = this.el.querySelector("#set-label")
    if (setLabel) setLabel.textContent = event.label || ""

    // Clock center
    const clockTop     = this.el.querySelector("#clock-top")
    const clockPrimary = this.el.querySelector("#clock-primary")
    const clockBottom  = this.el.querySelector("#clock-bottom")

    if (isWork) {
      const secPerRep = event.sec_per_burpee || (event.duration_sec / (event.burpee_count || 1))
      const repsLeft  = Math.max(Math.ceil((event.duration_sec - phase_elapsed) / secPerRep), 0)
      if (clockTop)     clockTop.textContent          = "reps left"
      if (clockPrimary) {
        clockPrimary.textContent = repsLeft
        clockPrimary.style.color = ""
      }
      if (clockBottom)  clockBottom.textContent       = "of " + event.burpee_count
    } else if (isRest) {
      if (clockTop)     clockTop.textContent     = "rest"
      if (clockPrimary) {
        clockPrimary.textContent = this.formatTime(phase_remaining)
        // Yellow countdown when ≤5s remain
        clockPrimary.style.color = isWarning ? "#F59E0B" : ""
      }
      if (clockBottom)  clockBottom.textContent  = ""
    }

    // Burpee counter (main only)
    const repsDone = this.el.querySelector("#reps-done")
    if (repsDone) repsDone.textContent = this.mainBurpeeCount
  },

  // ---------------------------------------------------------------------------
  // Completion
  // ---------------------------------------------------------------------------

  onComplete(elapsed) {
    if (this.rafId) cancelAnimationFrame(this.rafId)

    // Warmup duration = elapsed up to warmupEndSec (or total warmup sec)
    const warmupDuration = Math.min(elapsed, this.warmupEndSec)
    const mainDuration   = Math.max(Math.round(elapsed - warmupDuration), 0)

    this.onCompleted()   // fanfare

    this.pushEvent("session_complete", {
      main:   {burpee_count_done: this.mainBurpeeCount,   duration_sec: mainDuration},
      warmup: {burpee_count_done: this.warmupBurpeeCount, duration_sec: Math.round(warmupDuration)}
    })
  },

  // ---------------------------------------------------------------------------
  // Audio core (carried over from BurpeeHook)
  // ---------------------------------------------------------------------------

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

  tickAt(startAt, {freq, durMs, gain, type = "sine", attackMs = 3}) {
    const ctx = this.audioContext()
    const dur = durMs / 1000
    const osc = ctx.createOscillator()
    const g   = ctx.createGain()
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

  chimeAt(startAt, {freq, durMs = 300, gain = 0.4}) {
    const ctx = this.audioContext()
    const dur = durMs / 1000
    const partials = [
      {m: 1, g: 1.0, d: dur},
      {m: 2, g: 0.4, d: dur * 0.7},
      {m: 3, g: 0.2, d: dur * 0.5}
    ]
    const master = ctx.createGain()
    master.gain.value = gain
    master.connect(this.masterBus())
    partials.forEach(p => {
      const osc = ctx.createOscillator()
      const g   = ctx.createGain()
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
    this.tickAt(t, {freq: 440, durMs: 150, gain: 0.6, type: "triangle"})
  },

  repBeepAt(t) {
    this.tickAt(t,  {freq: 800,    durMs: 40,  gain: 0.7, type: "square", attackMs: 2})
    this.chimeAt(t, {freq: 659.25, durMs: 350, gain: 0.8})
    this.tickAt(t,  {freq: 329.63, durMs: 200, gain: 0.4, type: "triangle"})
  },

  onCompleted() {
    this.stopAudio()
    const now = this.audioContext().currentTime
    this.chimeAt(now,       {freq: 523.25, durMs: 250, gain: 0.4})
    this.chimeAt(now + 0.2, {freq: 659.25, durMs: 300, gain: 0.4})
    this.chimeAt(now + 0.4, {freq: 783.99, durMs: 350, gain: 0.5})
    this.chimeAt(now + 0.6, {freq: 1046.5, durMs: 900, gain: 0.5})
  },

  trackOsc(osc) {
    this.scheduledOscs.push(osc)
    osc.addEventListener("ended", () => {
      this.scheduledOscs = this.scheduledOscs.filter(o => o !== osc)
    })
  },

  stopAudio() {
    if (!this.ctx) return
    const now = this.ctx.currentTime
    this.scheduledOscs.forEach(osc => { try { osc.stop(now) } catch (_) {} })
    this.scheduledOscs = []
  },

  // ---------------------------------------------------------------------------
  // Wake lock
  // ---------------------------------------------------------------------------

  acquireWakeLock() {
    if (this.wakeLock) return
    navigator.wakeLock?.request("screen").then(lock => {
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
  },

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  formatTime(sec) {
    const s = Math.max(Math.ceil(sec), 0)
    const m = Math.floor(s / 60)
    const r = s % 60
    return m > 0 ? `${m}:${String(r).padStart(2, "0")}` : `${r}`
  },

  phaseLabel(type) {
    const labels = {
      work_burpee:  "Work",
      warmup_burpee:"Warmup",
      work_rest:    "Rest",
      warmup_rest:  "Warmup rest",
      rest_block:   "Rest"
    }
    return labels[type] || "Ready"
  },

  // Returns the accent color for the current phase (ring, progress bar fill).
  phaseColor(type, isWarning) {
    if (isWarning) return "#F59E0B"
    const colors = {
      work_burpee:   "#4A9EFF",
      warmup_burpee: "#F59E0B",
      work_rest:     "#6B8FA8",
      warmup_rest:   "#6B8FA8",
      rest_block:    "#6B8FA8"
    }
    return colors[type] || "#1E2535"
  },

  // Returns {bg, text} for the phase badge.
  phaseBadgeStyle(type, isWarning) {
    if (isWarning) return {bg: "#2D1F08", text: "#F59E0B"}
    const styles = {
      work_burpee:   {bg: "#1A2D4A", text: "#4A9EFF"},
      warmup_burpee: {bg: "#2D1F08", text: "#F59E0B"},
      work_rest:     {bg: "#141E28", text: "#6B8FA8"},
      warmup_rest:   {bg: "#141E28", text: "#6B8FA8"},
      rest_block:    {bg: "#141E28", text: "#6B8FA8"}
    }
    return styles[type] || {bg: "#11141C", text: "#9BA8BF"}
  }
}

export default SessionHook
