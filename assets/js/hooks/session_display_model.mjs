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
	const isRest = event?.phase === "rest";
	const isWork = event?.phase === "work";
	const progress = ringProgressForFrame(frame);

	const isRestCountdown =
		isRest &&
		(frame?.phase_remaining ?? timeLeftSec ?? Infinity) <= 3 &&
		(frame?.phase_remaining ?? timeLeftSec ?? 0) > 0;

	return {
		mode: isRestCountdown ? "countdown" : isRest ? "rest" : "work",
		phaseLabel: isRestCountdown ? "starting in" : "",
		ring: { kind: "session", progress },
		primaryCount: isRestCountdown
			? Math.ceil(frame?.phase_remaining ?? timeLeftSec ?? 0)
			: isRest
				? formatTime(frame?.phase_remaining ?? timeLeftSec)
				: isWork
					? Math.max((event?.burpee_count || 0) - doneInEvent, 0)
					: (event?.burpee_count ?? totalTarget ?? "—"),
		countdownDots: isRestCountdown
			? {
					count: 3,
					faded: Math.max(
						3 - Math.ceil(frame?.phase_remaining ?? timeLeftSec ?? 0),
						0,
					),
				}
			: null,
		restTimeLeftSec: isRest ? (frame?.phase_remaining ?? timeLeftSec) : null,
		totalDone,
		totalTarget,
		timeLeftSec,
		setGlyphs: activeSegmentGlyphs({ timeline, frame }),
	};
}

function activeSegmentGlyphs({ timeline, frame }) {
	const workEvents = (timeline || []).filter((event) => event.phase === "work");
	if (workEvents.length === 0) return [];

	const completedSets = (timeline || [])
		.slice(0, frame?.index ?? timeline.length)
		.filter((event) => event.phase === "work").length;
	const currentSetProgress =
		frame?.event?.phase === "work" && frame.event.duration_sec > 0
			? clamp((frame.phase_elapsed || 0) / frame.event.duration_sec)
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
	if (!event?.duration_sec) return 0;

	if (event.phase === "work") {
		const burpeeCount = event.burpee_count || 1;
		const secondsPerRep =
			event.sec_per_rep ||
			event.sec_per_burpee ||
			event.duration_sec / burpeeCount;
		if (!secondsPerRep || secondsPerRep <= 0) return 0;
		return clamp(((frame.phase_elapsed || 0) % secondsPerRep) / secondsPerRep);
	}

	return clamp((frame?.phase_elapsed || 0) / event.duration_sec);
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
