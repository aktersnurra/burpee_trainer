export function initialSessionState() {
  return {
    mode: "idle",
    timeline: [],
    mainTimeline: [],
    blockCount: 0,
    mood: null,
    clock: {
      startTime: null,
      pauseTime: null,
      hiddenAt: null,
      elapsedSec: 0,
      totalDurationSec: 0,
      warmupEndSec: 0,
    },
    reps: {
      currentEventKey: null,
      doneInEvent: 0,
      mainDone: 0,
      warmupDone: 0,
    },
    countdown: {
      value: null,
      paused: false,
      stepStartedAt: null,
      stepElapsedMs: 0,
    },
  };
}

export function currentFrame(timeline, elapsedSec) {
  let cursor = 0;

  for (let index = 0; index < timeline.length; index++) {
    const event = timeline[index];
    if (elapsedSec < cursor + event.duration_sec) {
      return {
        event,
        index,
        phase_elapsed: elapsedSec - cursor,
        phase_remaining: event.duration_sec - (elapsedSec - cursor),
      };
    }
    cursor += event.duration_sec;
  }

  return null;
}

export function eventKey(frameOrEvent, fallbackIndex = 0) {
  if (!frameOrEvent) return null;
  const event = frameOrEvent.event || frameOrEvent;
  const index = Number.isInteger(frameOrEvent.index) ? frameOrEvent.index : fallbackIndex;
  return `${index}:${event.type}:${event.label || ""}`;
}

export function accountReps(previousFrame, nextFrame, reps) {
  if (!previousFrame || !previousFrame.event) return reps;

  const previousEvent = previousFrame.event;
  const previousKey = eventKey(previousFrame);
  const nextKey = eventKey(nextFrame);

  if (previousKey === nextKey) return reps;
  if (previousEvent.type !== "work_burpee" && previousEvent.type !== "warmup_burpee") return reps;

  const target = previousEvent.burpee_count || 0;
  const doneInEvent = reps.currentEventKey === previousKey ? reps.doneInEvent : 0;
  const missing = Math.max(target - doneInEvent, 0);

  if (missing === 0) {
    return {...reps, currentEventKey: nextKey, doneInEvent: 0};
  }

  if (previousEvent.type === "warmup_burpee") {
    return {
      ...reps,
      currentEventKey: nextKey,
      doneInEvent: 0,
      warmupDone: reps.warmupDone + missing,
    };
  }

  return {
    ...reps,
    currentEventKey: nextKey,
    doneInEvent: 0,
    mainDone: reps.mainDone + missing,
  };
}

export function transition(state, event) {
  switch (event.type) {
    case "SESSION_READY":
      return {
        state: {
          ...state,
          mode: "warmup_prompt",
          mainTimeline: event.timeline || [],
          blockCount: event.blockCount || 0,
        },
        commands: [{type: "renderPrompt"}],
      };

    case "WARMUP_SKIP":
      return {
        state: {
          ...state,
          mode: "mood_prompt",
          timeline: state.mainTimeline,
        },
        commands: [{type: "renderMoodPrompt"}],
      };

    case "WARMUP_YES":
      return {state, commands: [{type: "pushWarmupRequested"}]};

    case "WARMUP_READY":
      return {
        state: {
          ...state,
          mode: "mood_prompt",
          timeline: [...(event.warmup || []), ...state.mainTimeline],
        },
        commands: [{type: "renderMoodPrompt"}],
      };

    case "MOOD_SELECTED":
      return {
        state: {
          ...state,
          mode: "countdown",
          mood: event.mood,
          countdown: {...state.countdown, value: 5, paused: false, stepStartedAt: event.now || null},
        },
        commands: [
          {type: "pushSessionStarted", mood: event.mood},
          {type: "startCountdownTimer"},
        ],
      };

    case "COUNTDOWN_DONE": {
      const totalDurationSec = state.timeline.reduce((sum, item) => sum + item.duration_sec, 0);
      const warmupEndSec = state.timeline
        .filter((item) => item.type === "warmup_burpee" || item.type === "warmup_rest")
        .reduce((sum, item) => sum + item.duration_sec, 0);

      return {
        state: {
          ...state,
          mode: "running",
          clock: {
            ...state.clock,
            startTime: event.now || null,
            totalDurationSec,
            warmupEndSec,
          },
        },
        commands: [{type: "startAnimationFrame"}],
      };
    }

    case "WORKOUT_DONE":
      return {
        state: {...state, mode: "completed"},
        commands: [{type: "pushSessionComplete"}],
      };

    default:
      return {state, commands: []};
  }
}
