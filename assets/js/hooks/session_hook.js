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

const CX = 140, CY = 140, R = 107;
const CIRC = 2 * Math.PI * R;
const GAP_DEG = 3.5;
const NS = "http://www.w3.org/2000/svg";
const COL = {
  done: "#4A9EFF",
  doneBg: "#1A2D4A",
  current: "#FFFFFF",
  currentBg: "#1E2535",
  upcoming: "#141B26",
};

const SessionHook = {
  mounted() {
    this.ctx = null;
    this.bus = null;
    this.scheduledOscs = [];
    this.wakeLock = null;

    this.timeline = [];
    this.mainTimeline = [];
    this.startTime = null;
    this.totalDuration = 0;
    this.paused = false;
    this.pauseTime = null;
    this.rafId = null;
    this.countdownPaused = false;
    this.countdownCount = null;
    this.countdownTimeoutId = null;
    this.countdownStepStarted = null; // performance.now() when the current step began
    this.countdownStepElapsed = 0;    // ms elapsed in the current step when paused

    this.lastRepIndex = -1;
    this.lastRestCount = null;
    this.warmupBurpeeCount = 0;
    this.mainBurpeeCount = 0;
    this.warmupEndSec = 0; // elapsed time when warmup phase ends

    this.rings = [];
    this.doneReps = 0;
    this.totalReps = 0;
    this.downTimeout = null;
    this.lastDisplayed = -1;
    this.lastEventType = null;
    this.lastBurpeeCount = 0;
    this.restRingEl = null;
    this.countdownRingEl = null;

    this.hiddenAt = null; // track when tab went hidden for pause accounting

    this.onVisibility = () => {
      if (document.visibilityState === "hidden") {
        // Screen locked / tab backgrounded — pause the clock silently.
        if (!this.paused && this.startTime !== null) {
          this.hiddenAt = performance.now();
          if (this.rafId) cancelAnimationFrame(this.rafId);
          this.rafId = null;
          this.stopAudio();
        }
      } else {
        // Tab visible again — absorb the gap into startTime so elapsed is unaffected.
        if (!this.paused && this.hiddenAt !== null && this.startTime !== null) {
          this.startTime += performance.now() - this.hiddenAt;
        }
        this.hiddenAt = null;
        this.maybeReacquireWakeLock();
        // Restart the RAF loop if we were running.
        if (!this.paused && this.startTime !== null && !this.rafId) {
          this.rafId = requestAnimationFrame(() => this.tick());
        }
      }
    };
    document.addEventListener("visibilitychange", this.onVisibility);

    this.primeAudio = () => this.ensureRunningAudio();
    document.addEventListener("click", this.primeAudio, { capture: true });
    document.addEventListener("touchstart", this.primeAudio, {
      capture: true,
      passive: true,
    });

    this.handleEvent("session_ready", ({ timeline }) => {
      this.mainTimeline = timeline;
      this.showWarmupPrompt();
    });

    this.handleEvent("warmup_ready", ({ warmup }) => {
      this.timeline = [...warmup, ...this.mainTimeline];
      this.startCountdown();
    });

    // Event delegation on the outer hook element — survives LiveView re-renders
    // because the hook root (#burpee-session) is never replaced.
    this.el.addEventListener("click", (e) => {
      const warmupYes = e.target.closest("#warmup-yes-btn");
      const warmupSkip = e.target.closest("#warmup-skip-btn");
      const ringContainer = e.target.closest("#ring-container");
      const finishEarly = e.target.closest("#finish-early-btn");

      if (warmupYes) this.onWarmupYes();
      if (warmupSkip) this.onWarmupSkip();
      if (ringContainer && (this.startTime !== null || this.countdownCount !== null)) this.togglePause();
      if (finishEarly) this.onFinishEarly();
    });
  },

  destroyed() {
    if (this.rafId) cancelAnimationFrame(this.rafId);
    this.stopAudio();
    document.removeEventListener("visibilitychange", this.onVisibility);
    document.removeEventListener("click", this.primeAudio, { capture: true });
    document.removeEventListener("touchstart", this.primeAudio, {
      capture: true,
    });
    this.releaseWakeLock();
    if (this.ctx) this.ctx.close();
  },

  // ---------------------------------------------------------------------------
  // Session flow
  // ---------------------------------------------------------------------------

  showWarmupPrompt() {
    // Overlay is already rendered by the server; nothing to do here.
  },

  onWarmupYes() {
    this.pushEvent("warmup_requested", {});
    // server responds with warmup_ready → startCountdown()
  },

  onWarmupSkip() {
    this.timeline = this.mainTimeline;
    this.showMoodPicker();
  },

  showMoodPicker() {
    const overlay = this.el.querySelector("#start-overlay");
    if (!overlay) return;

    const moodIcons = {
      "-1": `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M15.182 16.318A4.486 4.486 0 0 0 12.016 15a4.486 4.486 0 0 0-3.198 1.318M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0ZM9.75 9.75c0 .414-.168.75-.375.75S9 10.164 9 9.75 9.168 9 9.375 9s.375.336.375.75Zm-.375 0h.008v.015h-.008V9.75Zm5.625 0c0 .414-.168.75-.375.75s-.375-.336-.375-.75.168-.75.375-.75.375.336.375.75Zm-.375 0h.008v.015h-.008V9.75Z" /></svg>`,
      "0": `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M15 12H9m12 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z" /></svg>`,
      "1": `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="m3.75 13.5 10.5-11.25L12 10.5h8.25L9.75 21.75 12 13.5H3.75Z" /></svg>`,
    };

    // Patch the overlay in-place — delegation on the hook root catches the clicks.
    overlay.innerHTML = `
      <span class="text-xl font-semibold tracking-tight">How do you feel?</span>
      <div class="flex gap-3">
        ${[
          ["Tired", "-1"],
          ["OK", "0"],
          ["Hyped", "1"],
        ]
          .map(
            ([label, val]) => `
          <button type="button" data-mood="${val}"
            class="flex flex-col items-center gap-1.5 rounded-xl border border-[#1E2535] px-5 py-3 text-sm font-medium transition active:scale-[0.97] hover:bg-[#181C26]">
            ${moodIcons[val]}
            <span>${label}</span>
          </button>
        `,
          )
          .join("")}
      </div>
    `;

    // Delegation won't reach data-mood — wire these directly since the overlay is JS-owned.
    overlay.querySelectorAll("[data-mood]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const mood = btn.getAttribute("data-mood");
        this.pushEvent("session_started", { mood });
        this.startCountdown();
      });
    });
  },

  // Show a 5-4-3-2-1 countdown overlay before the workout clock begins.
  // Color ramp: 5=amber, 4=amber-orange, 3=orange, 2=orange-red, 1=red
  countdownColor(n) {
    return (
      ["#EF4444", "#F97316", "#F97316", "#F59E0B", "#F59E0B"][n] || "#F59E0B"
    );
  },

  startCountdown() {
    this.ensureRunningAudio();
    this.acquireWakeLock();

    const overlay = this.el.querySelector("#start-overlay");
    if (overlay) overlay.remove();

    // Build a single amber ring in #ring-svg for the countdown
    const svgEl = this.el.querySelector("#ring-svg");
    if (svgEl) {
      while (svgEl.firstChild) svgEl.removeChild(svgEl.firstChild);
      const cdRing = document.createElementNS(NS, "circle");
      cdRing.setAttribute("cx", CX);
      cdRing.setAttribute("cy", CY);
      cdRing.setAttribute("r", R);
      cdRing.setAttribute("fill", "none");
      cdRing.setAttribute("stroke-width", "16");
      cdRing.setAttribute("stroke-linecap", "round");
      cdRing.setAttribute("transform", `rotate(-90 ${CX} ${CY})`);
      cdRing.setAttribute("stroke-dasharray", CIRC.toFixed(4));
      cdRing.setAttribute("stroke-dashoffset", "0");
      cdRing.setAttribute("stroke", this.countdownColor(5));
      svgEl.appendChild(cdRing);
      this.countdownRingEl = cdRing;
    }

    const countEl = this.el.querySelector("#count");
    if (countEl) countEl.style.visibility = "";

    const showCount = (n, animate) => {
      const color = this.countdownColor(n);

      if (countEl) {
        countEl.textContent = n;
        countEl.style.color = color;
        countEl.classList.remove("countdown-pop");
        void countEl.offsetWidth;
        countEl.classList.add("countdown-pop");
      }

      if (this.countdownRingEl) {
        const remaining = n / 5;
        this.countdownRingEl.style.transition = animate
          ? "stroke-dashoffset 0.8s ease-out, stroke 0.3s"
          : "none";
        this.countdownRingEl.setAttribute("stroke-dasharray", CIRC.toFixed(4));
        this.countdownRingEl.setAttribute(
          "stroke-dashoffset",
          (CIRC * (1 - remaining)).toFixed(4),
        );
        this.countdownRingEl.setAttribute("stroke", color);
      }
    };

    this.countdownShowCount = showCount;

    // scheduleNext: show `n` after `delayMs`, then continue.
    // countdownCount tracks the number currently *visible* on screen.
    const scheduleNext = (n, delayMs = 1000) => {
      this.countdownStepStarted = performance.now();
      this.countdownTimeoutId = setTimeout(() => {
        if (this.countdownPaused) return;
        if (n >= 1) {
          this.countdownCount = n;
          showCount(n, true);
          this.leadBeepAt(this.audioContext().currentTime + 0.02);
          scheduleNext(n - 1);
        } else {
          this.countdownCount = null;
          this.countdownTimeoutId = null;
          this.countdownStepStarted = null;
          if (countEl) {
            countEl.style.color = "#C8D8F0";
            countEl.textContent = "—";
          }
          this.beginSession();
        }
      }, delayMs);
    };

    // Render 5 with no transition — ring stays full, no animation flash.
    this.countdownCount = 5;
    showCount(5, false);
    this.leadBeepAt(this.audioContext().currentTime + 0.02);
    scheduleNext(4);
  },

  beginSession() {
    this.totalDuration = this.timeline.reduce((s, e) => s + e.duration_sec, 0);
    this.warmupEndSec = this.timeline
      .filter((e) => e.type === "warmup_burpee" || e.type === "warmup_rest")
      .reduce((s, e) => s + e.duration_sec, 0);

    const finishEarlyBtn = this.el.querySelector("#finish-early-btn");
    if (finishEarlyBtn) finishEarlyBtn.removeAttribute("disabled");

    // Clear countdown ring; build segmented ring for the first event
    this.countdownRingEl = null;
    this.lastEventType = null;
    this.lastBurpeeCount = 0;

    const firstEvent = this.timeline[0];
    const isFirstWork =
      firstEvent &&
      (firstEvent.type === "work_burpee" || firstEvent.type === "warmup_burpee");
    if (isFirstWork) {
      this.buildRings(firstEvent.burpee_count);
      this.triggerDown(firstEvent.burpee_count);
      this.lastEventType = firstEvent.type;
      this.lastBurpeeCount = firstEvent.burpee_count;
    }

    this.startTime = performance.now();
    this.rafId = requestAnimationFrame(() => this.tick());
  },

  // ---------------------------------------------------------------------------
  // Clock loop
  // ---------------------------------------------------------------------------

  tick() {
    const now = performance.now();
    const elapsed = (now - this.startTime) / 1000;
    const state = this.currentEvent(elapsed);

    this.updateUI(state, elapsed);
    this.checkBeeps(state, elapsed);

    if (!this.paused && elapsed < this.totalDuration) {
      this.rafId = requestAnimationFrame(() => this.tick());
    } else if (elapsed >= this.totalDuration) {
      this.onComplete(elapsed);
    }
  },

  currentEvent(elapsed_sec) {
    let cursor = 0;
    for (const event of this.timeline) {
      if (elapsed_sec < cursor + event.duration_sec) {
        return {
          event,
          phase_elapsed: elapsed_sec - cursor,
          phase_remaining: event.duration_sec - (elapsed_sec - cursor),
        };
      }
      cursor += event.duration_sec;
    }
    return null;
  },

  // ---------------------------------------------------------------------------
  // Pause / resume
  // ---------------------------------------------------------------------------

  togglePause() {
    if (this.countdownCount !== null) {
      if (this.countdownPaused) {
        this.resumeCountdown();
      } else {
        this.pauseCountdown();
      }
      return;
    }
    if (this.paused) {
      this.resume();
    } else {
      this.pause();
    }
  },

  pauseCountdown() {
    this.countdownPaused = true;
    if (this.countdownTimeoutId) {
      clearTimeout(this.countdownTimeoutId);
      this.countdownTimeoutId = null;
    }
    // Record how much of the current 1-second step has already elapsed.
    this.countdownStepElapsed = this.countdownStepStarted !== null
      ? performance.now() - this.countdownStepStarted
      : 0;
    this.stopAudio();
    this.updatePauseBtn(true);
  },

  resumeCountdown() {
    this.countdownPaused = false;
    this.updatePauseBtn(false);

    const n = this.countdownCount;
    if (n === null) return;

    const scheduleNext = (n, delayMs = 1000) => {
      this.countdownStepStarted = performance.now();
      this.countdownTimeoutId = setTimeout(() => {
        if (this.countdownPaused) return;
        if (n >= 1) {
          this.countdownCount = n;
          this.countdownShowCount(n, true);
          this.leadBeepAt(this.audioContext().currentTime + 0.02);
          scheduleNext(n - 1);
        } else {
          this.countdownCount = null;
          this.countdownTimeoutId = null;
          this.countdownStepStarted = null;
          const countEl = this.el.querySelector("#count");
          if (countEl) {
            countEl.style.color = "#C8D8F0";
            countEl.textContent = "—";
          }
          this.beginSession();
        }
      }, delayMs);
    };

    // Show the current number and wait only the remaining portion of its second.
    this.countdownShowCount(n, false);
    const elapsed = this.countdownStepElapsed || 0;
    const remaining = Math.max(1000 - elapsed, 0);
    scheduleNext(n - 1, remaining);
  },

  pause() {
    if (this.paused) return;
    this.paused = true;
    this.pauseTime = performance.now();
    if (this.rafId) cancelAnimationFrame(this.rafId);
    this.stopAudio();
    this.updatePauseBtn(true);
  },

  resume() {
    if (!this.paused) return;
    this.startTime += performance.now() - this.pauseTime;
    this.paused = false;
    this.hiddenAt = null;
    this.rafId = requestAnimationFrame(() => this.tick());
    this.updatePauseBtn(false);
  },

  updatePauseBtn(paused) {
    const pauseIcon = this.el.querySelector("#pause-icon");
    const countEl = this.el.querySelector("#count");
    const downEl = this.el.querySelector("#down-word");
    const ringContainer = this.el.querySelector("#ring-container");

    if (paused) {
      if (countEl) countEl.style.visibility = "hidden";
      if (downEl) downEl.style.display = "none";
      if (pauseIcon) pauseIcon.style.display = "";
      if (ringContainer) ringContainer.style.opacity = "0.6";
    } else {
      if (pauseIcon) pauseIcon.style.display = "none";
      if (ringContainer) ringContainer.style.opacity = "";
      if (countEl) countEl.style.visibility = "";
    }
  },

  onFinishEarly() {
    if (!confirm("End the session now and log what you've done so far?"))
      return;
    const elapsed = (performance.now() - this.startTime) / 1000;
    this.onComplete(elapsed);
  },

  // ---------------------------------------------------------------------------
  // Beeps
  // ---------------------------------------------------------------------------

  checkBeeps(state, elapsed) {
    if (!state) return;
    const { event, phase_elapsed, phase_remaining } = state;

    // Rep beep: fire once per rep boundary within a burpee phase
    if (event.type === "work_burpee" || event.type === "warmup_burpee") {
      const secPerRep =
        event.sec_per_rep ||
        event.sec_per_burpee ||
        event.duration_sec / (event.burpee_count || 1);
      const repIndex = Math.floor(phase_elapsed / secPerRep);
      if (repIndex !== this.lastRepIndex) {
        this.lastRepIndex = repIndex;
        this.repBeepAt(this.audioContext().currentTime + 0.02);
      }
    } else {
      this.lastRepIndex = -1;
    }

    // Rest-ending countdown: lead beep at 2 and 1, rep beep at 0 (first burpee of next set).
    // Safe if rest < 2s — countSec will simply never reach 2 so nothing fires early.
    const REST_TYPES = ["work_rest", "warmup_rest", "rest_block"];
    if (REST_TYPES.includes(event.type)) {
      if (phase_remaining <= 2) {
        const countSec = Math.ceil(phase_remaining); // 2, 1, 0
        if (countSec !== this.lastRestCount) {
          this.lastRestCount = countSec;
          if (countSec === 0) {
            this.repBeepAt(this.audioContext().currentTime + 0.02);
          } else {
            this.leadBeepAt(this.audioContext().currentTime + 0.02);
          }
        }
      } else {
        this.lastRestCount = null;
      }
    } else {
      this.lastRestCount = null;
    }
  },

  // ---------------------------------------------------------------------------
  // UI updates (direct DOM writes for high-frequency elements)
  // ---------------------------------------------------------------------------

  updateUI(state, elapsed) {
    const totalSec = this.totalDuration;
    const timeLeft = Math.max(totalSec - elapsed, 0);

    // Overall progress bar — fills over the whole workout
    const overallPct =
      totalSec > 0 ? Math.min((elapsed / totalSec) * 100, 100) : 0;
    const fill = this.el.querySelector("#progress-fill");
    if (fill) fill.style.width = overallPct.toFixed(1) + "%";

    const timeLeftEl = this.el.querySelector("#time-left");
    if (timeLeftEl) timeLeftEl.textContent = this.formatTime(timeLeft);

    if (!state) return;

    const { event, phase_elapsed, phase_remaining } = state;
    const isWork =
      event.type === "work_burpee" || event.type === "warmup_burpee";
    const isRest =
      event.type === "work_rest" ||
      event.type === "warmup_rest" ||
      event.type === "rest_block";
    const isWarning = isRest && phase_remaining <= 5;

    const color = this.phaseColor(event.type, isWarning);

    // Overall progress bar color
    if (fill) fill.style.backgroundColor = isWarning ? "#F59E0B" : color;

    // Phase badge
    const badge = this.el.querySelector("#phase-badge");
    if (badge) {
      const { bg, text } = this.phaseBadgeStyle(event.type, isWarning);
      badge.textContent = this.phaseLabel(event.type);
      badge.style.backgroundColor = bg;
      badge.style.color = text;
      badge.className =
        "inline-flex items-center rounded-full px-2.5 py-1 text-[13px] font-medium uppercase tracking-[0.06em]";
    }

    const setLabel = this.el.querySelector("#set-label");
    if (setLabel) setLabel.textContent = event.label || "";

    if (isWork) {
      // Rebuild segments when entering a new work event
      if (
        event.type !== this.lastEventType ||
        event.burpee_count !== this.lastBurpeeCount
      ) {
        this.buildRings(event.burpee_count);
        this.triggerDown(event.burpee_count);
        this.lastEventType = event.type;
        this.lastBurpeeCount = event.burpee_count;
      }

      const secPerRep =
        event.sec_per_rep ||
        event.sec_per_burpee ||
        event.duration_sec / (event.burpee_count || 1);
      const repIndex = Math.floor(phase_elapsed / secPerRep);
      const repElapsed = phase_elapsed - repIndex * secPerRep;
      const repProgress = repElapsed / secPerRep;

      // Falling edge — rep completed
      if (repIndex > this.doneReps) {
        this.triggerFlash();
        this.doneReps = repIndex;
        if (event.type === "warmup_burpee") {
          this.warmupBurpeeCount++;
          this.updateTotalCounter(this.warmupBurpeeCount + this.mainBurpeeCount);
        } else {
          this.mainBurpeeCount++;
          this.updateTotalCounter(this.mainBurpeeCount);
        }
        this.triggerDown(Math.max(this.totalReps - this.doneReps, 0));
      }

      this.updateRings(repProgress);
    } else if (isRest) {
      // Build a single continuous arc for rest phases
      if (event.type !== this.lastEventType) {
        const svgEl = this.el.querySelector("#ring-svg");
        if (svgEl) {
          while (svgEl.firstChild) svgEl.removeChild(svgEl.firstChild);
          const restRing = document.createElementNS(NS, "circle");
          restRing.setAttribute("cx", CX);
          restRing.setAttribute("cy", CY);
          restRing.setAttribute("r", R);
          restRing.setAttribute("fill", "none");
          restRing.setAttribute("stroke-width", "16");
          restRing.setAttribute("stroke-linecap", "round");
          restRing.setAttribute("transform", `rotate(-90 ${CX} ${CY})`);
          svgEl.appendChild(restRing);
          this.restRingEl = restRing;
        }
        this.rings = [];
        this.lastEventType = event.type;
        this.lastBurpeeCount = 0;
      }

      const phasePct =
        event.duration_sec > 0 ? phase_elapsed / event.duration_sec : 0;
      const offset = CIRC * (1 - Math.min(phasePct, 1));
      const rColor = isWarning ? "#F59E0B" : "#6B8FA8";
      if (this.restRingEl) {
        this.restRingEl.setAttribute("stroke", rColor);
        this.restRingEl.setAttribute("stroke-dasharray", CIRC.toFixed(4));
        this.restRingEl.setAttribute("stroke-dashoffset", offset.toFixed(4));
      }

      const countEl = this.el.querySelector("#count");
      if (countEl) {
        countEl.style.visibility = "";
        countEl.textContent = this.formatTime(phase_remaining);
        countEl.style.color = isWarning ? "#F59E0B" : "#C8D8F0";
      }
      const downEl = this.el.querySelector("#down-word");
      if (downEl) downEl.style.display = "none";
    }
  },

  // ---------------------------------------------------------------------------
  // Segmented ring
  // ---------------------------------------------------------------------------

  buildRings(n) {
    this.totalReps = n;
    this.doneReps = 0;
    this.lastDisplayed = -1;
    const svgEl = this.el.querySelector("#ring-svg");
    if (!svgEl) return;
    while (svgEl.firstChild) svgEl.removeChild(svgEl.firstChild);
    this.rings = [];

    const segDeg = 360 / n;
    const arcDeg = segDeg - GAP_DEG;
    const arcLen = (arcDeg / 360) * CIRC;
    const gapLen = (GAP_DEG / 360) * CIRC;
    const period = arcLen + gapLen;

    const bg = document.createElementNS(NS, "circle");
    bg.setAttribute("cx", CX);
    bg.setAttribute("cy", CY);
    bg.setAttribute("r", R);
    bg.setAttribute("fill", "none");
    bg.setAttribute("stroke", "#0D1017");
    bg.setAttribute("stroke-width", "18");
    bg.setAttribute(
      "stroke-dasharray",
      `${arcLen.toFixed(3)} ${gapLen.toFixed(3)}`,
    );
    bg.setAttribute("transform", `rotate(-90 ${CX} ${CY})`);
    svgEl.appendChild(bg);

    for (let i = 0; i < n; i++) {
      const baseOffset = -(i * period);

      const track = document.createElementNS(NS, "circle");
      track.setAttribute("cx", CX);
      track.setAttribute("cy", CY);
      track.setAttribute("r", R);
      track.setAttribute("fill", "none");
      track.setAttribute("stroke", COL.upcoming);
      track.setAttribute("stroke-width", "16");
      track.setAttribute(
        "stroke-dasharray",
        `${arcLen.toFixed(3)} ${(CIRC - arcLen).toFixed(3)}`,
      );
      track.setAttribute("stroke-dashoffset", baseOffset.toFixed(3));
      track.setAttribute("transform", `rotate(-90 ${CX} ${CY})`);

      const fill = document.createElementNS(NS, "circle");
      fill.setAttribute("cx", CX);
      fill.setAttribute("cy", CY);
      fill.setAttribute("r", R);
      fill.setAttribute("fill", "none");
      fill.setAttribute("stroke", COL.upcoming);
      fill.setAttribute("stroke-width", "16");
      fill.setAttribute("stroke-dasharray", `0 ${CIRC.toFixed(3)}`);
      fill.setAttribute("stroke-dashoffset", baseOffset.toFixed(3));
      fill.setAttribute("stroke-linecap", "butt");
      fill.setAttribute("transform", `rotate(-90 ${CX} ${CY})`);

      svgEl.appendChild(track);
      svgEl.appendChild(fill);
      this.rings.push({ track, fill, arcLen, baseOffset });
    }
  },

  updateRings(repProgress) {
    for (let i = 0; i < this.totalReps; i++) {
      const { track, fill, arcLen, baseOffset } = this.rings[i];
      if (i < this.doneReps) {
        track.setAttribute("stroke", COL.doneBg);
        fill.setAttribute("stroke", COL.done);
        fill.setAttribute(
          "stroke-dasharray",
          `${arcLen.toFixed(3)} ${(CIRC - arcLen).toFixed(3)}`,
        );
        fill.setAttribute("stroke-dashoffset", baseOffset.toFixed(3));
      } else if (i === this.doneReps && this.doneReps < this.totalReps) {
        const filledLen = arcLen * Math.min(repProgress, 1);
        track.setAttribute("stroke", COL.currentBg);
        fill.setAttribute("stroke", COL.current);
        fill.setAttribute(
          "stroke-dasharray",
          `${filledLen.toFixed(3)} ${(CIRC - filledLen).toFixed(3)}`,
        );
        fill.setAttribute("stroke-dashoffset", baseOffset.toFixed(3));
      } else {
        track.setAttribute("stroke", COL.upcoming);
        fill.setAttribute("stroke", COL.upcoming);
        fill.setAttribute("stroke-dasharray", `0 ${CIRC.toFixed(3)}`);
      }
    }
  },

  triggerDown(repsLeft) {
    if (this.downTimeout) clearTimeout(this.downTimeout);
    const countEl = this.el.querySelector("#count");
    const downEl = this.el.querySelector("#down-word");
    if (!countEl || !downEl) return;

    // Hard cut: hide count, show "Down" instantly
    countEl.style.visibility = "hidden";
    downEl.style.display = "";

    this.downTimeout = setTimeout(() => {
      this.downTimeout = null;
      // Hard cut: hide "Down", show new count
      downEl.style.display = "none";
      countEl.textContent = repsLeft;
      countEl.style.color = "#C8D8F0";
      countEl.style.visibility = "";
      this.lastDisplayed = repsLeft;
    }, 350);
  },

  triggerFlash() {
    const flashEl = this.el.querySelector("#flash-circle");
    if (!flashEl) return;
    flashEl.style.transition = "none";
    flashEl.setAttribute("opacity", "0.5");
    requestAnimationFrame(() =>
      requestAnimationFrame(() => {
        flashEl.style.transition = "opacity 0.2s ease-out";
        flashEl.setAttribute("opacity", "0");
      }),
    );
  },

  updateTotalCounter(n) {
    const el = this.el.querySelector("#total-done");
    if (!el) return;
    el.textContent = n;
    el.style.color = "#FFFFFF";
    setTimeout(() => {
      el.style.color = "";
    }, 160);
  },

  // ---------------------------------------------------------------------------
  // Completion
  // ---------------------------------------------------------------------------

  onComplete(elapsed) {
    if (this.rafId) cancelAnimationFrame(this.rafId);

    // Warmup duration = elapsed up to warmupEndSec (or total warmup sec)
    const warmupDuration = Math.min(elapsed, this.warmupEndSec);
    const mainDuration = Math.max(Math.round(elapsed - warmupDuration), 0);

    this.onCompleted(); // fanfare

    this.pushEvent("session_complete", {
      main: {
        burpee_count_done: this.mainBurpeeCount,
        duration_sec: mainDuration,
      },
      warmup: {
        burpee_count_done: this.warmupBurpeeCount,
        duration_sec: Math.round(warmupDuration),
      },
    });
  },

  // ---------------------------------------------------------------------------
  // Audio core (carried over from BurpeeHook)
  // ---------------------------------------------------------------------------

  audioContext() {
    if (!this.ctx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      this.ctx = new AC();
    }
    return this.ctx;
  },

  ensureRunningAudio() {
    const ctx = this.audioContext();
    if (ctx.state === "suspended") ctx.resume().catch(() => {});
  },

  masterBus() {
    const ctx = this.audioContext();
    if (!this.bus) {
      this.bus = ctx.createGain();
      this.bus.gain.value = 1.0;
      this.bus.connect(ctx.destination);
    }
    return this.bus;
  },

  tickAt(startAt, { freq, durMs, gain, type = "sine", attackMs = 3 }) {
    const ctx = this.audioContext();
    const dur = durMs / 1000;
    const osc = ctx.createOscillator();
    const g = ctx.createGain();
    osc.type = type;
    osc.frequency.setValueAtTime(freq, startAt);
    g.gain.setValueAtTime(0, startAt);
    g.gain.linearRampToValueAtTime(gain, startAt + attackMs / 1000);
    g.gain.exponentialRampToValueAtTime(0.0001, startAt + dur);
    osc.connect(g);
    g.connect(this.masterBus());
    osc.start(startAt);
    osc.stop(startAt + dur + 0.05);
    this.trackOsc(osc);
  },

  chimeAt(startAt, { freq, durMs = 300, gain = 0.4 }) {
    const ctx = this.audioContext();
    const dur = durMs / 1000;
    const partials = [
      { m: 1, g: 1.0, d: dur },
      { m: 2, g: 0.4, d: dur * 0.7 },
      { m: 3, g: 0.2, d: dur * 0.5 },
    ];
    const master = ctx.createGain();
    master.gain.value = gain;
    master.connect(this.masterBus());
    partials.forEach((p) => {
      const osc = ctx.createOscillator();
      const g = ctx.createGain();
      osc.frequency.setValueAtTime(freq * p.m, startAt);
      g.gain.setValueAtTime(0, startAt);
      g.gain.linearRampToValueAtTime(p.g, startAt + 0.005);
      g.gain.exponentialRampToValueAtTime(0.0001, startAt + p.d);
      osc.connect(g);
      g.connect(master);
      osc.start(startAt);
      osc.stop(startAt + p.d + 0.05);
      this.trackOsc(osc);
    });
  },

  leadBeepAt(t) {
    this.tickAt(t, { freq: 440, durMs: 150, gain: 0.6, type: "triangle" });
  },

  repBeepAt(t) {
    this.tickAt(t, {
      freq: 800,
      durMs: 40,
      gain: 0.7,
      type: "square",
      attackMs: 2,
    });
    this.chimeAt(t, { freq: 659.25, durMs: 350, gain: 0.8 });
    this.tickAt(t, { freq: 329.63, durMs: 200, gain: 0.4, type: "triangle" });
  },

  onCompleted() {
    this.stopAudio();
    const now = this.audioContext().currentTime;
    this.chimeAt(now, { freq: 523.25, durMs: 250, gain: 0.4 });
    this.chimeAt(now + 0.2, { freq: 659.25, durMs: 300, gain: 0.4 });
    this.chimeAt(now + 0.4, { freq: 783.99, durMs: 350, gain: 0.5 });
    this.chimeAt(now + 0.6, { freq: 1046.5, durMs: 900, gain: 0.5 });
  },

  trackOsc(osc) {
    this.scheduledOscs.push(osc);
    osc.addEventListener("ended", () => {
      this.scheduledOscs = this.scheduledOscs.filter((o) => o !== osc);
    });
  },

  stopAudio() {
    if (!this.ctx) return;
    const now = this.ctx.currentTime;
    this.scheduledOscs.forEach((osc) => {
      try {
        osc.stop(now);
      } catch (_) {}
    });
    this.scheduledOscs = [];
  },

  // ---------------------------------------------------------------------------
  // Wake lock
  // ---------------------------------------------------------------------------

  acquireWakeLock() {
    if (this.wakeLock) return;
    navigator.wakeLock
      ?.request("screen")
      .then((lock) => {
        this.wakeLock = lock;
      })
      .catch(() => {});
  },

  maybeReacquireWakeLock() {
    if (document.visibilityState === "visible") {
      this.wakeLock = null;
      this.acquireWakeLock();
    }
  },

  releaseWakeLock() {
    this.wakeLock?.release?.().catch(() => {});
    this.wakeLock = null;
  },

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  formatTime(sec) {
    const s = Math.max(Math.ceil(sec), 0);
    const m = Math.floor(s / 60);
    const r = s % 60;
    return m > 0 ? `${m}:${String(r).padStart(2, "0")}` : `${r}`;
  },

  phaseLabel(type) {
    const labels = {
      work_burpee: "Work",
      warmup_burpee: "Warmup",
      work_rest: "Rest",
      warmup_rest: "Warmup rest",
      rest_block: "Rest",
    };
    return labels[type] || "Ready";
  },

  // Returns the accent color for the current phase (ring, progress bar fill).
  phaseColor(type, isWarning) {
    if (isWarning) return "#F59E0B";
    const colors = {
      work_burpee: "#4A9EFF",
      warmup_burpee: "#F59E0B",
      work_rest: "#6B8FA8",
      warmup_rest: "#6B8FA8",
      rest_block: "#6B8FA8",
    };
    return colors[type] || "#1E2535";
  },

  // Returns {bg, text} for the phase badge.
  phaseBadgeStyle(type, isWarning) {
    if (isWarning) return { bg: "#2D1F08", text: "#F59E0B" };
    const styles = {
      work_burpee: { bg: "#1A2D4A", text: "#4A9EFF" },
      warmup_burpee: { bg: "#2D1F08", text: "#F59E0B" },
      work_rest: { bg: "#141E28", text: "#6B8FA8" },
      warmup_rest: { bg: "#141E28", text: "#6B8FA8" },
      rest_block: { bg: "#141E28", text: "#6B8FA8" },
    };
    return styles[type] || { bg: "#11141C", text: "#9BA8BF" };
  },
};

export default SessionHook;
