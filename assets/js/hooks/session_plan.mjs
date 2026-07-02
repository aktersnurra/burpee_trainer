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

export function setBarsFromProgram(program) {
	return workoutTimelineFromProgram(program)
		.filter((event) => eventKind(event) === "work")
		.map((event, index) => {
			const setIndex = index + 1;

			return {
				id: `work-${setIndex}`,
				index: setIndex,
				reps: event.reps || 0,
				label: `Set ${setIndex}`,
			};
		});
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
			id: "warmup-work-001",
			kind: "work",
			reps: warmupReps,
			sec_per_rep: secPerRep,
			label: "Warmup Round 1",
		},
		{
			id: "warmup-rest-001",
			kind: "rest",
			duration_sec: 120,
			label: "Warmup Rest",
		},
		{
			id: "warmup-work-002",
			kind: "work",
			reps: warmupReps,
			sec_per_rep: secPerRep,
			label: "Warmup Round 2",
		},
		{
			id: "warmup-rest-002",
			kind: "rest",
			duration_sec: 180,
			label: "Warmup Rest",
		},
	];
}

function eventKind(event) {
	return event?.kind;
}
