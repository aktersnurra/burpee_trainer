export function countdownDisplayModel({
	value,
	total = 5,
	setGlyphs = [],
	totalDone,
	totalTarget,
	timeLeftSec,
}) {
	return {
		mode: "countdown",
		phaseLabel: "starting in",
		ring: { kind: "session", progress: 1 - value / total },
		visual: { state: "initial-countdown", progress: 0, pulse: null },
		primaryCount: value,
		countdownDots: { count: total, faded: Math.max(total - value, 0) },
		setGlyphs,
		totalDone,
		totalTarget,
		timeLeftSec,
	};
}

export function runningDisplayModel({
	timeline,
	frame,
	timeLeftSec,
	totalDone,
	totalTarget,
	doneInEvent = 0,
}) {
	const event = frame?.event;
	const kind = eventKind(event);
	const isRest = kind === "rest";
	const isWork = kind === "work";
	const progress = ringProgressForFrame(frame);
	const remainingSec = frame?.phase_remaining ?? timeLeftSec ?? 0;
	const visual = visualStateForFrame({
		isRest,
		isWork,
		remainingSec,
		progress,
	});
	const isRestCountdown = isRest && remainingSec <= 3 && remainingSec > 0;

	return {
		mode: isRestCountdown ? "countdown" : isRest ? "rest" : "work",
		phaseLabel: isRestCountdown ? "starting in" : "",
		ring: { kind: "session", progress },
		visual,
		primaryCount:
			visual.state === "rest-countdown"
				? visual.pulse
				: isRest
					? formatTime(remainingSec)
					: isWork
						? Math.max((event?.reps || 0) - doneInEvent, 0)
						: (event?.reps ?? totalTarget ?? "—"),
		countdownDots: null,
		restTimeLeftSec: isRest ? remainingSec : null,
		totalDone,
		totalTarget,
		timeLeftSec,
		setGlyphs: activeSegmentGlyphs({ timeline, frame }),
	};
}

function visualStateForFrame({ isRest, isWork, remainingSec, progress }) {
	if (isWork) {
		return { state: "work", progress, pulse: null };
	}

	if (!isRest) {
		return { state: "work", progress: 0, pulse: null };
	}

	if (remainingSec > 5) {
		return { state: "rest-breathe", progress: 0, pulse: null };
	}

	if (remainingSec > 3) {
		return { state: "rest-settle", progress: 0, pulse: null };
	}

	const pulse = remainingSec > 0 ? Math.ceil(remainingSec) : null;
	return { state: "rest-countdown", progress: 0, pulse };
}

function activeSegmentGlyphs({ timeline, frame }) {
	const workEvents = (timeline || []).filter(
		(event) => eventKind(event) === "work",
	);
	if (workEvents.length === 0) return [];

	const completedSets = (timeline || [])
		.slice(0, frame?.index ?? timeline.length)
		.filter((event) => eventKind(event) === "work").length;
	const currentSetDurationSec = eventDurationSec(frame?.event);
	const currentSetProgress =
		eventKind(frame?.event) === "work" && currentSetDurationSec > 0
			? clamp((frame.phase_elapsed || 0) / currentSetDurationSec)
			: null;

	return [
		{
			setCount: workEvents.length,
			completedSets,
			currentSetProgress,
		},
	];
}

function ringProgressForFrame(frame) {
	const event = frame?.event;
	const durationSec = eventDurationSec(event);
	if (durationSec <= 0) return 0;

	if (eventKind(event) === "work") {
		const secondsPerRep = event.sec_per_rep;
		if (!secondsPerRep || secondsPerRep <= 0) return 0;
		return clamp(((frame.phase_elapsed || 0) % secondsPerRep) / secondsPerRep);
	}

	return clamp((frame?.phase_elapsed || 0) / durationSec);
}

function eventDurationSec(event) {
	if (event?.kind === "work")
		return (event.reps || 0) * (event.sec_per_rep || 0);
	if (event?.kind === "rest") return event.duration_sec || 0;
	return 0;
}

function eventKind(event) {
	return event?.kind;
}

function clamp(value) {
	return Math.min(Math.max(value, 0), 1);
}

function formatTime(sec) {
	const s = Math.max(Math.ceil(sec || 0), 0);
	const m = Math.floor(s / 60);
	const r = s % 60;
	return m > 0 ? `${m}:${String(r).padStart(2, "0")}` : `${r}`;
}
