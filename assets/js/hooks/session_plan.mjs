// Client-owned runner program projection.
// Phoenix sends immutable execution program data; this module exposes the
// runnable warmup/workout segments used by the browser FSM.
export function workoutTimelineFromProgram(program) {
	return Array.isArray(program?.events) ? program.events : [];
}

export function programBurpeeCount(programOrEvents) {
	const events = Array.isArray(programOrEvents)
		? programOrEvents
		: workoutTimelineFromProgram(programOrEvents);

	return events.reduce((total, event) => {
		if (eventKind(event) !== "work") return total;
		return total + (event.reps || 0);
	}, 0);
}

// How many of the plan's sets (its work events) are whole within `repsDone` scheduled reps.
export function setsReached(timeline, repsDone) {
	let reps = 0;
	let done = 0;
	let total = 0;
	for (const event of timeline) {
		if (eventKind(event) !== "work") continue;
		total += 1;
		reps += event.reps || 0;
		if (reps <= repsDone) done += 1;
	}
	return { done, total };
}

export function warmupTimelineFromProgram(program) {
	const firstWork = workoutTimelineFromProgram(program).find(
		(event) => eventKind(event) === "work",
	);

	if (!firstWork) return [];

	const secPerRep = firstWork.sec_per_rep;
	if (!secPerRep || secPerRep <= 0) return [];
	const secPerBurpee = firstWork.sec_per_burpee || secPerRep;

	const warmupReps = Math.min(firstWork.reps || 0, Math.trunc(60 / secPerRep));
	if (warmupReps <= 0) return [];

	return [
		{
			kind: "work",
			reps: warmupReps,
			sec_per_rep: secPerRep,
			sec_per_burpee: secPerBurpee,
		},
		{
			kind: "rest",
			duration_sec: 120,
		},
		{
			kind: "work",
			reps: warmupReps,
			sec_per_rep: secPerRep,
			sec_per_burpee: secPerBurpee,
		},
		{
			kind: "rest",
			duration_sec: 180,
		},
	];
}

function eventKind(event) {
	return event?.kind;
}
