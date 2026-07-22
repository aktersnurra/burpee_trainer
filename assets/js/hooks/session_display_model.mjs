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
	total = 5,
	totalDone,
	totalTarget,
	timeLeftSec,
	sessionProgress = null,
}) {
	return {
		visual: { state: "count_in", progress: 0, pulse: null },
		primaryCount: value,
		countdownDots: { count: total, faded: Math.max(total - value, 0) },
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

	return {
		visual,
		primaryCount:
			visual.state === "rest_count_in"
				? Math.max(Math.ceil(remainingSec), 1)
				: isRest
					? formatClock(remainingSec)
					: isWork
						? Math.max((event?.reps || 0) - doneInEvent, 0)
						: (event?.reps ?? totalTarget ?? "—"),
		countdownDots: null,
		restTimeLeftSec: isRest ? remainingSec : null,
		setProgress:
			visual.state === "rest" ? setProgressForFrame(timeline, frame) : null,
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

	const configuredActiveSec = Number(frame?.event?.sec_per_burpee);
	const activeSec =
		configuredActiveSec > 0
			? Math.min(configuredActiveSec, cadenceSec)
			: cadenceSec;
	const repElapsedSec = (frame?.phase_elapsed || 0) % cadenceSec;
	const recoverySec = cadenceSec - activeSec;

	return {
		state:
			recoverySec <= 0 || repElapsedSec < activeSec
				? "work_active"
				: "work_recovery",
		progress: clamp(repElapsedSec / cadenceSec),
		activeRatio: clamp(activeSec / cadenceSec),
		pulse: null,
	};
}

function setProgressForFrame(timeline, frame) {
	const total = timeline.filter((event) => eventKind(event) === "work").length;
	const completed = timeline
		.slice(0, frame?.index ?? 0)
		.filter((event) => eventKind(event) === "work").length;

	return total > 0 ? `${completed}/${total}` : null;
}

function eventKind(event) {
	return event?.kind;
}

function clamp(value) {
	return Math.min(Math.max(value, 0), 1);
}

function formatClock(sec) {
	const seconds = Math.max(Math.ceil(sec || 0), 0);
	const minutes = Math.floor(seconds / 60);
	const remainder = seconds % 60;
	return `${minutes}:${String(remainder).padStart(2, "0")}`;
}
