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
			workoutDurationSec: 0,
		},
		reps: {
			currentEventKey: null,
			doneInEvent: 0,
			mainDone: 0,
			warmupDone: 0,
			previousFrame: null,
		},
		countdown: {
			value: null,
			paused: false,
			stepStartedAt: null,
			stepElapsedMs: 0,
		},
		beeps: {
			lastRepIndex: -1,
			lastRestCount: null,
		},
		display: {
			lastEventType: null,
			lastBurpeeCount: 0,
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
	const index = Number.isInteger(frameOrEvent.index)
		? frameOrEvent.index
		: fallbackIndex;
	return `${index}:${event.type}:${event.label || ""}`;
}

export function accountReps(previousFrame, nextFrame, reps) {
	if (!previousFrame || !previousFrame.event) return reps;

	const previousEvent = previousFrame.event;
	const previousKey = eventKey(previousFrame);
	const nextKey = eventKey(nextFrame);

	if (previousKey === nextKey) return reps;
	if (
		previousEvent.type !== "work_burpee" &&
		previousEvent.type !== "warmup_burpee"
	)
		return reps;

	const target = previousEvent.burpee_count || 0;
	const doneInEvent =
		reps.currentEventKey === previousKey ? reps.doneInEvent : 0;
	const missing = Math.max(target - doneInEvent, 0);

	if (missing === 0) {
		return { ...reps, currentEventKey: nextKey, doneInEvent: 0 };
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

function beepCommandsForFrame(beeps, frame) {
	if (!frame) return { beeps, commands: [] };

	const { event: timelineEvent, phase_elapsed, phase_remaining } = frame;
	const isBurpee =
		timelineEvent.type === "work_burpee" ||
		timelineEvent.type === "warmup_burpee";

	if (isBurpee) {
		const secondsPerRep =
			timelineEvent.sec_per_rep ||
			timelineEvent.sec_per_burpee ||
			timelineEvent.duration_sec / (timelineEvent.burpee_count || 1);
		const repIndex = Math.floor(phase_elapsed / secondsPerRep);

		if (repIndex !== beeps.lastRepIndex) {
			return {
				beeps: { lastRepIndex: repIndex, lastRestCount: null },
				commands: [{ type: "playRepBeep" }],
			};
		}

		return { beeps: { ...beeps, lastRestCount: null }, commands: [] };
	}

	const isRest =
		timelineEvent.type === "work_rest" ||
		timelineEvent.type === "warmup_rest" ||
		timelineEvent.type === "rest_block";

	if (!isRest) {
		return { beeps: { lastRepIndex: -1, lastRestCount: null }, commands: [] };
	}

	if (phase_remaining > 2) {
		return { beeps: { lastRepIndex: -1, lastRestCount: null }, commands: [] };
	}

	const restCount = Math.ceil(phase_remaining);
	if (restCount === beeps.lastRestCount) {
		return { beeps: { ...beeps, lastRepIndex: -1 }, commands: [] };
	}

	return {
		beeps: { lastRepIndex: -1, lastRestCount: restCount },
		commands: [{ type: restCount === 0 ? "playRepBeep" : "playLeadBeep" }],
	};
}

function phaseColor(type, isWarning) {
	if (isWarning) return "#F59E0B";
	const colors = {
		work_burpee: "#4A9EFF",
		warmup_burpee: "#F59E0B",
		work_rest: "#6B8FA8",
		warmup_rest: "#6B8FA8",
		rest_block: "#6B8FA8",
	};
	return colors[type] || "#1E2535";
}

function blockLabel(label, blockCount) {
	if (!label) return "";
	const match = label.match(/Block (\d+)/);
	return match && blockCount > 0 ? `Block ${match[1]} of ${blockCount}` : "";
}

function displayCommandsForFrame(display, event) {
	const frame = event.frame;
	const totalDurationSec = event.totalDurationSec || 0;
	const warmupEndSec = event.warmupEndSec || 0;
	const elapsedSec = event.elapsedSec || 0;
	const workoutDurationSec = event.workoutDurationSec || Math.max(totalDurationSec - warmupEndSec, 0);
	const workoutElapsedSec = Math.max(elapsedSec - warmupEndSec, 0);
	const percent =
		workoutDurationSec > 0
			? Number(
					Math.min((workoutElapsedSec / workoutDurationSec) * 100, 100).toFixed(
						1,
					),
				)
			: 0;
	const timeLeftSec = Math.max(workoutDurationSec - workoutElapsedSec, 0);

	if (!frame) {
		return {
			display,
			commands: [
				{ type: "renderProgressBar", percent, color: "#1E2535" },
				{ type: "renderTimer", timeLeftSec },
			],
		};
	}

	const timelineEvent = frame.event;
	const isWork =
		timelineEvent.type === "work_burpee" ||
		timelineEvent.type === "warmup_burpee";
	const isRest =
		timelineEvent.type === "work_rest" ||
		timelineEvent.type === "warmup_rest" ||
		timelineEvent.type === "rest_block";
	const isWarning = isRest && frame.phase_remaining <= 5;
	const color = phaseColor(timelineEvent.type, isWarning);
	const commands = [
		{ type: "renderProgressBar", percent, color },
		{ type: "renderTimer", timeLeftSec },
		{
			type: "renderBlockLabel",
			label: blockLabel(timelineEvent.label, event.blockCount || 0),
		},
	];

	let nextDisplay = display;

	if (isWork) {
		const burpeeCount = timelineEvent.burpee_count || 0;
		const enteringWork =
			timelineEvent.type !== display.lastEventType ||
			burpeeCount !== display.lastBurpeeCount;
		if (enteringWork) {
			commands.push({
				type: "enterWorkPhase",
				eventType: timelineEvent.type,
				burpeeCount,
			});
			commands.push({
				type: "triggerDown",
				remainingReps: Math.max(burpeeCount - (event.doneInEvent || 0), 0),
			});
			nextDisplay = {
				lastEventType: timelineEvent.type,
				lastBurpeeCount: burpeeCount,
			};
		}

		const secondsPerRep =
			timelineEvent.sec_per_rep ||
			timelineEvent.sec_per_burpee ||
			timelineEvent.duration_sec / (burpeeCount || 1);
		const repIndex = Math.floor(frame.phase_elapsed / secondsPerRep);
		const repElapsed = frame.phase_elapsed - repIndex * secondsPerRep;
		commands.push({
			type: "renderWorkRepProgress",
			progress: repElapsed / secondsPerRep,
			color,
		});
	} else if (isRest) {
		if (timelineEvent.type !== display.lastEventType) {
			commands.push({ type: "enterRestPhase", eventType: timelineEvent.type });
			nextDisplay = {
				lastEventType: timelineEvent.type,
				lastBurpeeCount: 0,
			};
		}
		commands.push({
			type: "renderRestProgress",
			progress:
				timelineEvent.duration_sec > 0
					? frame.phase_elapsed / timelineEvent.duration_sec
					: 0,
			color,
			timeLeftSec: frame.phase_remaining,
		});
	}

	return { display: nextDisplay, commands };
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
				commands: [{ type: "renderPrompt" }],
			};

		case "WARMUP_SKIP":
			return {
				state: {
					...state,
					mode: "countdown",
					timeline: state.mainTimeline,
					countdown: {
						...state.countdown,
						value: 5,
						paused: false,
						stepStartedAt: event.now || null,
					},
				},
				commands: [
					{ type: "pushSessionStarted" },
					{ type: "startCountdownTimer" },
				],
			};

		case "WARMUP_YES":
			return { state, commands: [{ type: "pushWarmupRequested" }] };

		case "WARMUP_READY":
			return {
				state: {
					...state,
					mode: "countdown",
					timeline: [...(event.warmup || []), ...state.mainTimeline],
					countdown: {
						...state.countdown,
						value: 5,
						paused: false,
						stepStartedAt: event.now || null,
					},
				},
				commands: [
					{ type: "pushSessionStarted" },
					{ type: "startCountdownTimer" },
				],
			};

		case "COUNTDOWN_PAUSE":
			return {
				state: {
					...state,
					mode: "countdown_paused",
					countdown: {
						...state.countdown,
						paused: true,
						stepElapsedMs: Math.max(
							(event.now || 0) - (state.countdown.stepStartedAt || 0),
							0,
						),
					},
				},
				commands: [{ type: "pauseCountdownTimer" }],
			};

		case "COUNTDOWN_RESUME": {
			const remainingMs = Math.max(
				1000 - (state.countdown.stepElapsedMs || 0),
				0,
			);
			return {
				state: {
					...state,
					mode: "countdown",
					countdown: {
						...state.countdown,
						paused: false,
						stepStartedAt: event.now || null,
					},
				},
				commands: [{ type: "resumeCountdownTimer", remainingMs }],
			};
		}

		case "COUNTDOWN_TICK": {
			if (event.value >= 1) {
				return {
					state: {
						...state,
						countdown: {
							...state.countdown,
							value: event.value,
							stepStartedAt: event.now || null,
						},
					},
					commands: [
						{ type: "renderCountdown", value: event.value, animate: true },
						{ type: "playLeadBeep" },
						{
							type: "scheduleCountdownTick",
							nextValue: event.value - 1,
							delayMs: 1000,
						},
					],
				};
			}

			return {
				state: {
					...state,
					countdown: {
						...state.countdown,
						value: null,
						stepStartedAt: null,
					},
				},
				commands: [{ type: "clearCountdown" }, { type: "beginSession" }],
			};
		}

		case "COUNTDOWN_DONE": {
			const totalDurationSec = state.timeline.reduce(
				(sum, item) => sum + item.duration_sec,
				0,
			);
			const warmupEndSec = state.timeline
				.filter(
					(item) =>
						item.type === "warmup_burpee" || item.type === "warmup_rest",
				)
				.reduce((sum, item) => sum + item.duration_sec, 0);
			const workoutDurationSec = state.timeline
				.filter(
					(item) =>
						item.type !== "warmup_burpee" && item.type !== "warmup_rest",
				)
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
						workoutDurationSec,
					},
				},
				commands: [{ type: "startAnimationFrame" }],
			};
		}

		case "TICK": {
			if (event.elapsedSec >= state.clock.totalDurationSec) {
				return {
					state: { ...state, mode: "completed" },
					commands: [
						{ type: "renderRunningFrame", elapsedSec: event.elapsedSec },
						{ type: "completeWorkout", elapsedSec: event.elapsedSec },
					],
				};
			}

			return {
				state: {
					...state,
					clock: { ...state.clock, elapsedSec: event.elapsedSec },
				},
				commands: [
					{ type: "renderRunningFrame", elapsedSec: event.elapsedSec },
					{ type: "scheduleAnimationFrame" },
				],
			};
		}

		case "FINISH_EARLY":
			return {
				state: { ...state, mode: "completed" },
				commands: [{ type: "completeWorkout", elapsedSec: event.elapsedSec }],
			};

		case "DISPLAY_FRAME": {
			const result = displayCommandsForFrame(state.display, event);
			return {
				state: { ...state, display: result.display },
				commands: result.commands,
			};
		}

		case "ACCOUNT_REPS": {
			const nextReps = accountReps(
				state.reps.previousFrame,
				event.frame,
				state.reps,
			);
			return {
				state: {
					...state,
					reps: { ...nextReps, previousFrame: event.frame },
				},
				commands: [
					{ type: "updateVisibleRepTotal", mainDone: nextReps.mainDone },
				],
			};
		}

		case "BEEP_FRAME": {
			const result = beepCommandsForFrame(state.beeps, event.frame);
			return {
				state: { ...state, beeps: result.beeps },
				commands: result.commands,
			};
		}

		case "COMPLETE_SESSION": {
			const warmupDurationSec = Math.round(
				Math.min(event.elapsedSec, state.clock.warmupEndSec),
			);
			const mainDurationSec = Math.max(
				Math.round(event.elapsedSec - warmupDurationSec),
				0,
			);
			return {
				state: { ...state, mode: "completed" },
				commands: [
					{ type: "cancelAnimationFrame" },
					{ type: "playCompletionFanfare" },
					{
						type: "pushSessionComplete",
						payload: {
							main: {
								burpee_count_done: state.reps.mainDone,
								duration_sec: mainDurationSec,
							},
							warmup: {
								burpee_count_done: state.reps.warmupDone,
								duration_sec: warmupDurationSec,
							},
						},
					},
				],
			};
		}

		case "PAUSE":
			return {
				state: {
					...state,
					mode: "paused",
					clock: { ...state.clock, pauseTime: event.now || null },
				},
				commands: [{ type: "cancelAnimationFrame" }],
			};

		case "RESUME": {
			const pausedFor = Math.max(
				(event.now || 0) - (state.clock.pauseTime || 0),
				0,
			);
			return {
				state: {
					...state,
					mode: "running",
					clock: {
						...state.clock,
						startTime:
							state.clock.startTime === null
								? null
								: state.clock.startTime + pausedFor,
						pauseTime: null,
					},
				},
				commands: [{ type: "startAnimationFrame" }],
			};
		}

		case "VISIBILITY_HIDDEN":
			return {
				state: {
					...state,
					clock: { ...state.clock, hiddenAt: event.now || null },
				},
				commands: [{ type: "cancelAnimationFrame" }],
			};

		case "VISIBILITY_VISIBLE": {
			const hiddenFor = Math.max(
				(event.now || 0) - (state.clock.hiddenAt || 0),
				0,
			);
			return {
				state: {
					...state,
					clock: {
						...state.clock,
						startTime:
							state.clock.startTime === null
								? null
								: state.clock.startTime + hiddenFor,
						hiddenAt: null,
					},
				},
				commands: [{ type: "startAnimationFrame" }],
			};
		}

		case "WORKOUT_DONE":
			return {
				state: { ...state, mode: "completed" },
				commands: [{ type: "pushSessionComplete" }],
			};

		default:
			return { state, commands: [] };
	}
}
