export function sessionProgressForElapsed(elapsedSec, totalDurationSec) {
	const elapsed = Number(elapsedSec);
	const total = Number(totalDurationSec);
	if (!Number.isFinite(elapsed) || !Number.isFinite(total) || total <= 0) {
		return 0;
	}
	return clamp(elapsed / total);
}

export function countdownDisplayModel({
	value,
	totalDone,
	totalTarget,
	timeLeftSec,
	sessionProgress = null,
}) {
	return {
		visual: { state: "count_in", progress: 0, pulse: null },
		primaryCount: value,
		countdownDots: null,
		setProgress: null,
		sessionProgress,
		totalDone,
		totalTarget,
		timeLeftSec,
	};
}

export function runningDisplayModel({
	timeline = [],
	frame,
	timeLeftSec,
	sessionProgress = null,
	totalDone,
	totalTarget,
	doneInEvent = 0,
}) {
	const event = frame?.event;
	const kind = eventKind(event);
	const isRest = kind === "rest";
	const isWork = kind === "work";
	const remainingSec = frame?.phase_remaining ?? timeLeftSec ?? 0;
	const visual = visualStateForFrame({ isRest, isWork, remainingSec, frame });
	const recoveryRemainingSec =
		visual.state === "work_recovery" ? recoveryRemainingForFrame(frame) : null;

	return {
		visual,
		primaryCount:
			visual.state === "work_recovery"
				? formatClock(recoveryRemainingSec)
				: visual.state === "rest_count_in"
					? (recoveryLeadIn(frame) ?? Math.max(Math.ceil(remainingSec), 1))
					: isRest
						? formatClock(remainingSec)
						: isWork
							? Math.max((event?.reps || 0) - doneInEvent, 0)
							: (event?.reps ?? totalTarget ?? "—"),
		countdownDots: null,
		restTimeLeftSec: isRest ? remainingSec : recoveryRemainingSec,
		setProgress:
			["rest", "work_recovery"].includes(visual.state)
				? setProgressForFrame(timeline, frame)
				: null,
		sessionProgress,
		totalDone,
		totalTarget,
		timeLeftSec,
	};
}

function visualStateForFrame({ isRest, isWork, remainingSec, frame }) {
	if (isWork) return workVisualState(frame);

	if (!isRest) {
		return { state: "work_active", progress: 0, activeRatio: 1, pulse: null };
	}

	if (remainingSec > 3) {
		return { state: "rest", progress: 0, pulse: null };
	}

	return { state: "rest_count_in", progress: 0, pulse: null };
}

function workVisualState(frame) {
	const cadenceSec = Number(frame?.event?.sec_per_rep) || 0;
	if (cadenceSec <= 0) {
		return { state: "work_active", progress: 0, activeRatio: 1, pulse: null };
	}

	// The last three seconds before the next rep of an even-paced set count in like the
	// end of a rest, so every rep that follows a pause is announced the same way.
	if (recoveryLeadIn(frame) !== null) {
		return { state: "rest_count_in", progress: 0, pulse: null };
	}

	const configuredActiveSec = Number(frame?.event?.sec_per_burpee);
	const activeSec =
		configuredActiveSec > 0
			? Math.min(configuredActiveSec, cadenceSec)
			: cadenceSec;
	const repElapsedSec = (frame?.phase_elapsed || 0) % cadenceSec;
	const recoverySec = cadenceSec - activeSec;

	const recovery = recoverySec > 0 && repElapsedSec >= activeSec;

	return {
		state: recovery ? "work_recovery" : "work_active",
		progress: recovery ? 0 : clamp(repElapsedSec / activeSec),
		pulse: null,
	};
}

// Seconds (3, 2 or 1) until the next rep of this set, while recovering from the one
// before; null otherwise: for a gap of three seconds or less, and after the set's last
// rep, whose next phase counts itself in.
export function recoveryLeadIn(frame) {
	const event = frame?.event;
	const cadenceSec = Number(event?.sec_per_rep) || 0;
	if (event?.kind !== "work" || cadenceSec <= 0) return null;

	const configuredActiveSec = Number(event?.sec_per_burpee);
	const activeSec =
		configuredActiveSec > 0 ? Math.min(configuredActiveSec, cadenceSec) : cadenceSec;
	// Only a real pause is counted in; a gap of three seconds or less stays a clock.
	if (cadenceSec - activeSec <= 3) return null;

	const elapsed = frame?.phase_elapsed || 0;
	const repIndex = Math.floor(elapsed / cadenceSec);
	if (repIndex + 1 >= (event?.reps || 0)) return null;

	const intoRep = elapsed - repIndex * cadenceSec;
	if (intoRep < activeSec) return null;

	const lead = Math.ceil(cadenceSec - intoRep);
	return lead >= 1 && lead <= 3 ? lead : null;
}

function recoveryRemainingForFrame(frame) {
	const cadenceSec = Number(frame?.event?.sec_per_rep) || 0;
	if (cadenceSec <= 0) return 0;
	const repElapsedSec = (frame?.phase_elapsed || 0) % cadenceSec;
	return Math.max(cadenceSec - repElapsedSec, 0);
}

function setProgressForFrame(timeline, frame) {
	const total = timeline.filter((event) => eventKind(event) === "work").length;
	const completed = timeline
		.slice(0, frame?.index ?? 0)
		.filter((event) => eventKind(event) === "work").length;
	const position =
		eventKind(frame?.event) === "work" ? completed + 1 : completed;

	return total > 1 ? `${position}/${total}` : null;
}

function eventKind(event) {
	return event?.kind;
}

function clamp(value) {
	return Math.min(Math.max(value, 0), 1);
}

// Rest reads as a time, 0:23, so from across the room it is never taken for 23 reps.
export function formatClock(sec) {
	const total = Math.max(Math.ceil(sec || 0), 0);
	return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}
