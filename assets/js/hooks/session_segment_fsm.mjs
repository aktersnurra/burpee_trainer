export function initialSegmentState() {
	return {
		mode: "idle",
		timeline: [],
		blockCount: 0,
		clock: {
			startTime: null,
			pauseTime: null,
			hiddenAt: null,
			elapsedSec: 0,
			totalDurationSec: 0,
		},
		reps: {
			currentEventKey: null,
			doneInEvent: 0,
			burpeeCountDone: 0,
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

function isBurpeeEvent(event) {
	return event.type === "work_burpee" || event.type === "warmup_burpee";
}

function completedRepsInFrame(frame) {
	if (!frame || !frame.event || !isBurpeeEvent(frame.event)) return 0;

	const event = frame.event;
	const target = event.burpee_count || 0;
	const secondsPerRep =
		event.sec_per_rep ||
		event.sec_per_burpee ||
		event.duration_sec / (target || 1);

	return Math.min(Math.floor((frame.phase_elapsed || 0) / secondsPerRep), target);
}

export function accountReps(previousFrame, nextFrame, reps) {
	const nextKey = eventKey(nextFrame);

	if (!previousFrame || !previousFrame.event) {
		const completed = completedRepsInFrame(nextFrame);
		return {
			...reps,
			currentEventKey: nextKey,
			doneInEvent: completed,
			burpeeCountDone: reps.burpeeCountDone + completed,
		};
	}

	const previousEvent = previousFrame.event;
	const previousKey = eventKey(previousFrame);
	const isBurpee = isBurpeeEvent(previousEvent);

	if (previousKey === nextKey) {
		const completed = completedRepsInFrame(nextFrame);
		const doneInEvent = reps.currentEventKey === previousKey ? reps.doneInEvent : 0;
		const newlyCompleted = Math.max(completed - doneInEvent, 0);

		return {
			...reps,
			currentEventKey: nextKey,
			doneInEvent: Math.max(doneInEvent, completed),
			burpeeCountDone: reps.burpeeCountDone + newlyCompleted,
		};
	}

	if (!isBurpee) return { ...reps, currentEventKey: nextKey, doneInEvent: 0 };

	const target = previousEvent.burpee_count || 0;
	const doneInEvent = reps.currentEventKey === previousKey ? reps.doneInEvent : 0;
	const missing = Math.max(target - doneInEvent, 0);

	return {
		...reps,
		currentEventKey: nextKey,
		doneInEvent: completedRepsInFrame(nextFrame),
		burpeeCountDone: reps.burpeeCountDone + missing,
	};
}

function totalDurationSec(timeline) {
	return timeline.reduce((sum, item) => sum + item.duration_sec, 0);
}

function totalBurpeeCount(timeline) {
	return timeline.reduce((sum, item) => {
		if (!isBurpeeEvent(item)) return sum;
		return sum + (item.burpee_count || 0);
	}, 0);
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
	const elapsedSec = event.elapsedSec || 0;
	const percent =
		totalDurationSec > 0
			? Number(Math.min((elapsedSec / totalDurationSec) * 100, 100).toFixed(1))
			: 0;
	const timeLeftSec = Math.max(totalDurationSec - elapsedSec, 0);

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

function finalizeSegment(state, elapsedSec) {
	return {
		state: {
			...state,
			mode: "done",
			clock: { ...state.clock, elapsedSec },
			reps: { ...state.reps, previousFrame: null },
		},
		commands: [
			{ type: "cancelAnimationFrame" },
			{
				type: "segmentDone",
				result: {
					burpeeCountDone: state.reps.burpeeCountDone,
					durationSec: Math.round(elapsedSec),
				},
			},
		],
	};
}

export function segmentTransition(state, event) {
	switch (event.type) {
		case "SEGMENT_READY": {
			const timeline = event.timeline || [];
			return {
				state: {
					...initialSegmentState(),
					timeline,
					blockCount: event.blockCount || 0,
				},
				commands: [
					{ type: "updateVisibleRepTotal", burpeeCountDone: 0 },
					{ type: "updateVisibleRepGoal", burpeeCountTarget: totalBurpeeCount(timeline) },
					{ type: "renderProgressBar", percent: 0, color: "#1E2535" },
					{ type: "renderTimer", timeLeftSec: totalDurationSec(timeline) },
				],
			};
		}

		case "COUNTDOWN_START":
			return {
				state: {
					...state,
					mode: "countdown",
					countdown: {
						...state.countdown,
						value: 5,
						paused: false,
						stepStartedAt: event.now || null,
					},
				},
				commands: [{ type: "startCountdownTimer" }],
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
			const remainingMs = Math.max(1000 - (state.countdown.stepElapsedMs || 0), 0);
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
						{ type: "scheduleCountdownTick", nextValue: event.value - 1, delayMs: 1000 },
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
				commands: [{ type: "clearCountdown" }, { type: "beginSegment" }],
			};
		}

		case "COUNTDOWN_DONE":
			return {
				state: {
					...state,
					mode: "running",
					clock: {
						...state.clock,
						startTime: event.now || null,
						totalDurationSec: totalDurationSec(state.timeline),
					},
				},
				commands: [{ type: "startAnimationFrame" }],
			};

		case "TICK": {
			const frame = currentFrame(state.timeline, event.elapsedSec);

			if (event.elapsedSec < state.clock.totalDurationSec) {
				const nextReps = frame
					? {
							...accountReps(state.reps.previousFrame, frame, state.reps),
							previousFrame: frame,
						}
					: state.reps;

				return {
					state: {
						...state,
						clock: { ...state.clock, elapsedSec: event.elapsedSec },
						reps: nextReps,
					},
					commands: [
						{ type: "renderRunningFrame", elapsedSec: event.elapsedSec },
						{ type: "scheduleAnimationFrame" },
					],
				};
			}

			const repsAfterFrame = frame
				? accountReps(state.reps.previousFrame, frame, state.reps)
				: accountReps(state.reps.previousFrame, null, state.reps);
			const nextReps = frame ? accountReps(frame, null, repsAfterFrame) : repsAfterFrame;

			return {
				state: {
					...state,
					mode: "done",
					clock: { ...state.clock, elapsedSec: event.elapsedSec },
					reps: { ...nextReps, previousFrame: null },
				},
				commands: [
					{ type: "renderRunningFrame", elapsedSec: event.elapsedSec },
					{
						type: "segmentDone",
						result: {
							burpeeCountDone: nextReps.burpeeCountDone,
							durationSec: Math.round(event.elapsedSec),
						},
					},
				],
			};
		}

		case "DISPLAY_FRAME": {
			const result = displayCommandsForFrame(state.display, {
				...event,
				totalDurationSec: event.totalDurationSec || state.clock.totalDurationSec,
			});
			return {
				state: { ...state, display: result.display },
				commands: result.commands,
			};
		}

		case "ACCOUNT_REPS": {
			const nextReps = accountReps(state.reps.previousFrame, event.frame, state.reps);
			return {
				state: {
					...state,
					reps: { ...nextReps, previousFrame: event.frame },
				},
				commands: [
					{ type: "updateVisibleRepTotal", burpeeCountDone: nextReps.burpeeCountDone },
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

		case "FINISH_EARLY":
			return finalizeSegment(
				{
					...state,
					reps: accountReps(state.reps.previousFrame, null, state.reps),
				},
				event.elapsedSec,
			);

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
			const pausedFor = Math.max((event.now || 0) - (state.clock.pauseTime || 0), 0);
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
			const hiddenFor = Math.max((event.now || 0) - (state.clock.hiddenAt || 0), 0);
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

		default:
			return { state, commands: [] };
	}
}
