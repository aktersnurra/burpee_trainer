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
	repProgress = null,
	totalDone,
	totalTarget,
	countedAtSec,
	cameraTrusted = false,
}) {
	const event = frame?.event;
	const kind = eventKind(event);
	const isRest = kind === "rest";
	const isWork = kind === "work";
	const remainingSec = frame?.phase_remaining ?? timeLeftSec ?? 0;
	const beat = isWork
		? beatState({
				event,
				phaseElapsedSec: frame?.phase_elapsed || 0,
				countedAtSec,
				cameraTrusted,
			})
		: null;
	const visual = beat
		? {
				state: "work_active",
				progress: beat.fill,
				draining: beat.draining,
				pace: beat.pace,
				lead: beat.lead,
				pulse: null,
			}
		: visualStateForFrame({ isRest, remainingSec });

	return {
		visual,
		beat,
		primaryCount:
			visual.state === "rest_count_in"
				? Math.max(Math.ceil(remainingSec), 1)
				: isRest
					? formatClock(remainingSec)
					: beat
						? Math.max((event?.reps || 0) - beat.done, 0)
						: 0,
		countdownDots: null,
		restTimeLeftSec: isRest ? remainingSec : null,
		setProgress: visual.state === "rest" ? setProgressForFrame(timeline, frame) : null,
		sessionProgress,
		repProgress,
		totalDone,
		totalTarget,
		timeLeftSec,
	};
}

function visualStateForFrame({ isRest, remainingSec }) {
	// The timeline has ended, but the camera may still be settling its final rep.
	if (!isRest) {
		return { state: "work_active", progress: 1, pulse: null };
	}

	if (remainingSec > 3) {
		return { state: "rest", progress: 0, pulse: null };
	}

	return { state: "rest_count_in", progress: 0, pulse: null };
}

// Small enough to absorb float error at a beat or due time, never a real moment.
const EPS = 1e-9;

// A set as a run of beats. Rep k (from 1) has its beat at (k-1)c and is due at (k-1)c + a.
// A rep is done when the camera counts it (countedAtSec, seconds from the set's start, in
// order) or, without the camera, at its due time. The fill rises from the beat to the due
// time, holds full until the rep is done, then drains from where it stood to empty at the
// next beat. The set's last rep has no gap: once it is done the set is over.
export function beatState({ event, phaseElapsedSec, countedAtSec, cameraTrusted = false }) {
	const reps = event?.reps || 0;
	const c = Number(event?.sec_per_rep) || 0;
	const configured = Number(event?.sec_per_burpee);
	const a = configured > 0 ? Math.min(configured, c) : c;
	const t = Math.max(Number(phaseElapsedSec) || 0, 0);
	if (reps <= 0 || c <= 0) {
		return { repOn: 1, done: 0, fill: 1, draining: false, pace: "steady", lead: null };
	}

	const beatOf = (k) => (k - 1) * c;
	const dueOf = (k) => beatOf(k) + a;
	const doneAt = cameraTrusted
		? (countedAtSec || []).slice(0, reps)
		: Array.from({ length: reps }, (_, i) => dueOf(i + 1));
	const doneBy = (time) => doneAt.filter((at) => at <= time + EPS).length;

	// The fill at `time` with `n` reps done.
	const fillWith = (time, n) => {
		const next = beatOf(n + 1);
		if (n >= 1 && time < next - EPS) {
			const d = doneAt[n - 1];
			const from = fillWith(d, n - 1);
			return from * (1 - (time - d) / (next - d));
		}
		return clamp((time - next) / a);
	};

	const done = doneBy(t);
	if (done >= reps) {
		return { repOn: reps, done, fill: 0, draining: false, pace: lastPace(), lead: null };
	}

	const repOn = done + 1;
	const next = beatOf(repOn);
	const draining = done >= 1 && t < next - EPS;
	const fill = fillWith(t, done);
	const gap = done >= 1 ? next - doneAt[done - 1] : 0;
	const left = next - t;
	const lead = draining && gap > 3 + EPS && left <= 3 + EPS ? Math.ceil(left - EPS) : null;
	const pace = !cameraTrusted
		? "steady"
		: t > dueOf(repOn) + EPS
			? "behind"
			: lastPace();

	return { repOn, done, fill, draining, pace, lead };

	function lastPace() {
		if (!cameraTrusted || done < 1) return "steady";
		return dueOf(done) - doneAt[done - 1] >= 0.2 * a - EPS ? "ahead" : "steady";
	}
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
