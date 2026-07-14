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

export function warmupTimelineFromProgram(program) {
	const firstWork = workoutTimelineFromProgram(program).find(
		(event) => eventKind(event) === "work",
	);

	if (!firstWork) return [];

	const secPerRep = firstWork.sec_per_rep;
	if (!secPerRep || secPerRep <= 0) return [];

	const warmupReps = Math.min(firstWork.reps || 0, Math.trunc(60 / secPerRep));
	if (warmupReps <= 0) return [];

	return [
		{
			kind: "work",
			reps: warmupReps,
			sec_per_rep: secPerRep,
		},
		{
			kind: "rest",
			duration_sec: 120,
		},
		{
			kind: "work",
			reps: warmupReps,
			sec_per_rep: secPerRep,
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
