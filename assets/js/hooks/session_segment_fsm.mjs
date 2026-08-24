export function initialSegmentState() {
	return {
		mode: "idle",
		timeline: [],
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
			lastEventKey: null,
			lastEventType: null,
			lastBurpeeCount: 0,
			lastRemainingReps: null,
		},
	};
}

export function currentFrame(timeline, elapsedSec) {
	let cursor = 0;

	for (let index = 0; index < timeline.length; index++) {
		const event = timeline[index];
		const durationSec = eventDurationSec(event);
		if (elapsedSec < cursor + durationSec) {
			return {
				event,
				index,
				phase_elapsed: elapsedSec - cursor,
				phase_remaining: durationSec - (elapsedSec - cursor),
			};
		}
		cursor += durationSec;
	}

	return null;
}

export function eventDurationSec(event) {
	if (event?.kind === "work") {
		if (Number.isFinite(event.duration_sec)) return event.duration_sec;
		return (event.reps || 0) * (event.sec_per_rep || 0);
	}
	if (event?.kind === "rest") return event.duration_sec || 0;
	return 0;
}

export function eventKey(frameOrEvent, fallbackIndex = 0) {
	if (!frameOrEvent) return null;
	const event = frameOrEvent.event || frameOrEvent;
	const index = Number.isInteger(frameOrEvent.index)
		? frameOrEvent.index
		: fallbackIndex;
	return `${index}:${eventKind(event)}`;
}

function eventKind(event) {
	return event?.kind;
}

function isBurpeeEvent(event) {
	return eventKind(event) === "work";
}

function activeDurationSec(event) {
	const cadenceSec = Number(event?.sec_per_rep) || 0;
	if (cadenceSec <= 0) return 0;

	const configuredActiveSec = Number(event?.sec_per_burpee);
	return configuredActiveSec > 0
		? Math.min(configuredActiveSec, cadenceSec)
		: cadenceSec;
}

function completedRepsForElapsed(event, phaseElapsedSec) {
	if (!isBurpeeEvent(event)) return 0;

	const target = event.reps || 0;
	const cadenceSec = Number(event.sec_per_rep) || 0;
	const activeSec = activeDurationSec(event);
	const eventElapsedSec = Math.min(
		Math.max(Number(phaseElapsedSec) || 0, 0),
		eventDurationSec(event),
	);

	const activeBoundaryToleranceSec =
		Number.EPSILON *
		4 *
		Math.max(1, eventElapsedSec, activeSec, cadenceSec);

	if (cadenceSec <= 0 || eventElapsedSec + activeBoundaryToleranceSec < activeSec) {
		return 0;
	}

	return Math.min(
		Math.floor(
			(eventElapsedSec - activeSec + activeBoundaryToleranceSec) /
				cadenceSec,
		) + 1,
		target,
	);
}

function completedRepsInFrame(frame) {
	if (!frame || !frame.event) return 0;
	return completedRepsForElapsed(frame.event, frame.phase_elapsed);
}

function scheduledRepsAtElapsed(timeline, elapsedSec) {
	let cursor = 0;
	const timelineElapsedSec = Math.max(Number(elapsedSec) || 0, 0);

	return timeline.reduce((completed, event) => {
		const nextCompleted =
			completed + completedRepsForElapsed(event, timelineElapsedSec - cursor);
		cursor += eventDurationSec(event);
		return nextCompleted;
	}, 0);
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
		const doneInEvent =
			reps.currentEventKey === previousKey ? reps.doneInEvent : 0;
		const newlyCompleted = Math.max(completed - doneInEvent, 0);

		return {
			...reps,
			currentEventKey: nextKey,
			doneInEvent: Math.max(doneInEvent, completed),
			burpeeCountDone: reps.burpeeCountDone + newlyCompleted,
		};
	}

	if (!isBurpee) return { ...reps, currentEventKey: nextKey, doneInEvent: 0 };

	const target = previousEvent.reps || 0;
	const doneInEvent =
		reps.currentEventKey === previousKey ? reps.doneInEvent : 0;
	const missing = Math.max(target - doneInEvent, 0);

	const completed = completedRepsInFrame(nextFrame);

	return {
		...reps,
		currentEventKey: nextKey,
		doneInEvent: completed,
		burpeeCountDone: reps.burpeeCountDone + missing + completed,
	};
}

function totalDurationSec(timeline) {
	return timeline.reduce((sum, item) => sum + eventDurationSec(item), 0);
}

function totalBurpeeCount(timeline) {
	return timeline.reduce((sum, item) => {
		if (!isBurpeeEvent(item)) return sum;
		return sum + (item.reps || 0);
	}, 0);
}

function beepCommandsForFrame(beeps, frame) {
	if (!frame) return { beeps, commands: [] };

	const { event: timelineEvent, phase_elapsed, phase_remaining } = frame;

	if (eventKind(timelineEvent) === "work") {
		const secondsPerRep = timelineEvent.sec_per_rep;
		const repIndex = Math.floor(phase_elapsed / secondsPerRep);

		if (repIndex !== beeps.lastRepIndex) {
			return {
				beeps: { lastRepIndex: repIndex, lastRestCount: null },
				commands: [{ type: "playRepBeep" }],
			};
		}

		return { beeps: { ...beeps, lastRestCount: null }, commands: [] };
	}

	if (eventKind(timelineEvent) !== "rest") {
		return { beeps: { lastRepIndex: -1, lastRestCount: null }, commands: [] };
	}

	if (phase_remaining > 3) {
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

function displayCommandsForFrame(display, event) {
	const frame = event.frame;
	const totalDurationSec = event.totalDurationSec || 0;
	const elapsedSec = event.elapsedSec || 0;
	const timeLeftSec = Math.max(totalDurationSec - elapsedSec, 0);

	if (!frame) {
		return {
			display,
			commands: [{ type: "renderTimer", timeLeftSec }],
		};
	}

	const timelineEvent = frame.event;
	const frameEventKey = eventKey(frame);
	const kind = eventKind(timelineEvent);
	const isWork = kind === "work";
	const isRest = kind === "rest";
	const commands = [{ type: "renderTimer", timeLeftSec }];

	let nextDisplay = display;

	if (isWork) {
		const burpeeCount = timelineEvent.reps || 0;
		const remainingReps = Math.max(burpeeCount - (event.doneInEvent || 0), 0);
		const enteringWork =
			frameEventKey !== display.lastEventKey ||
			burpeeCount !== display.lastBurpeeCount;
		if (enteringWork) {
			commands.push({
				type: "enterWorkPhase",
				eventType: kind,
				burpeeCount,
			});
			commands.push({
				type: "triggerDown",
				remainingReps,
			});
			nextDisplay = {
				lastEventKey: frameEventKey,
				lastEventType: kind,
				lastBurpeeCount: burpeeCount,
				lastRemainingReps: remainingReps,
			};
		} else if (remainingReps !== display.lastRemainingReps) {
			commands.push({ type: "renderCurrentSetRepCount", remainingReps });
			nextDisplay = { ...display, lastRemainingReps: remainingReps };
		}

		const secondsPerRep = timelineEvent.sec_per_rep;
		const repIndex = Math.floor(frame.phase_elapsed / secondsPerRep);
		const repElapsed = frame.phase_elapsed - repIndex * secondsPerRep;
		commands.push({
			type: "renderWorkRepProgress",
			progress: repElapsed / secondsPerRep,
		});
	} else if (isRest) {
		if (frameEventKey !== display.lastEventKey) {
			commands.push({ type: "enterRestPhase", eventType: kind });
			nextDisplay = {
				lastEventKey: frameEventKey,
				lastEventType: kind,
				lastBurpeeCount: 0,
				lastRemainingReps: null,
			};
		}
		commands.push({
			type: "renderRestProgress",
			timeLeftSec: frame.phase_remaining,
		});
	}

	return { display: nextDisplay, commands };
}

function segmentResult(reps, elapsedSec) {
	return {
		burpeeCountDone: reps.burpeeCountDone,
		scheduledRepsDone: reps.burpeeCountDone,
		durationSec: Math.round(elapsedSec),
	};
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
				result: segmentResult(state.reps, elapsedSec),
			},
		],
	};
}

function completeTimelineReps(state, reps) {
	return {
		...reps,
		burpeeCountDone: scheduledRepsAtElapsed(
			state.timeline,
			state.clock.totalDurationSec,
		),
		previousFrame: null,
	};
}

function tickSegment(state, event) {
	const frame = currentFrame(state.timeline, event.elapsedSec);

	if (event.elapsedSec < state.clock.totalDurationSec) {
		const nextReps = frame
			? {
					...accountReps(state.reps.previousFrame, frame, state.reps),
					burpeeCountDone: scheduledRepsAtElapsed(
						state.timeline,
						event.elapsedSec,
					),
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
	const nextReps = completeTimelineReps(
		state,
		frame ? accountReps(frame, null, repsAfterFrame) : repsAfterFrame,
	);
	const completionElapsedSec = state.clock.totalDurationSec;

	return {
		state: {
			...state,
			mode: "done",
			clock: { ...state.clock, elapsedSec: completionElapsedSec },
			reps: nextReps,
		},
		commands: [
			{ type: "renderRunningFrame", elapsedSec: completionElapsedSec },
			{
				type: "segmentDone",
				result: segmentResult(nextReps, completionElapsedSec),
			},
		],
	};
}

export function segmentTransition(state, event) {
	switch (event.type) {
		case "SEGMENT_READY": {
			const timeline = event.timeline || [];
			const burpeeCountTarget =
				event.burpeeCountTarget ?? totalBurpeeCount(timeline);
			return {
				state: {
					...initialSegmentState(),
					timeline,
				},
				commands: [
					{ type: "updateVisibleRepTotal", burpeeCountDone: 0 },
					{
						type: "updateVisibleRepGoal",
						burpeeCountTarget,
					},
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
					reps: {
						...state.reps,
						previousFrame: currentFrame(state.timeline, 0),
					},
				},
				commands: [{ type: "startAnimationFrame" }],
			};

		case "TICK":
			return tickSegment(state, event);

		case "DISPLAY_FRAME": {
			const result = displayCommandsForFrame(state.display, {
				...event,
				totalDurationSec:
					event.totalDurationSec || state.clock.totalDurationSec,
			});
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
					{
						type: "updateVisibleRepTotal",
						burpeeCountDone: nextReps.burpeeCountDone,
					},
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

		case "FINISH_EARLY": {
			const accountedReps = accountReps(
				state.reps.previousFrame,
				currentFrame(state.timeline, event.elapsedSec),
				state.reps,
			);
			const completedReps = scheduledRepsAtElapsed(
				state.timeline,
				event.elapsedSec,
			);

			return finalizeSegment(
				{
					...state,
					reps: {
						...accountedReps,
						burpeeCountDone: completedReps,
					},
				},
				event.elapsedSec,
			);
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
			const inactiveStart = [state.clock.hiddenAt, state.clock.pauseTime]
				.filter((time) => time !== null)
				.reduce(
					(earliest, time) =>
						earliest === null ? time : Math.min(earliest, time),
					null,
				);
			const inactiveFor =
				inactiveStart === null
					? 0
					: Math.max((event.now || 0) - inactiveStart, 0);
			return {
				state: {
					...state,
					mode: "running",
					clock: {
						...state.clock,
						startTime:
							state.clock.startTime === null
								? null
								: state.clock.startTime + inactiveFor,
						pauseTime: null,
						hiddenAt: null,
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

		default:
			return { state, commands: [] };
	}
}
