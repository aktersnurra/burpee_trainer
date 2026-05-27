export function workoutTimelineFromPlan(plan) {
	return sortedBlocks(plan).flatMap((block) => blockTimeline(block));
}

export function warmupTimelineFromPlan(plan) {
	const firstBlock = sortedBlocks(plan)[0];
	const firstSet = firstBlock ? sortedSets(firstBlock)[0] : null;

	if (!firstSet) return [];

	const secPerBurpee = plan.sec_per_burpee || firstSet.sec_per_burpee || firstSet.sec_per_rep;
	if (!secPerBurpee || secPerBurpee <= 0) return [];

	const warmupReps = Math.min(firstSet.burpee_count || 0, Math.trunc(60 / secPerBurpee));
	if (warmupReps <= 0) return [];

	const durationSec = warmupReps * secPerBurpee;

	return [
		{
			type: "warmup_burpee",
			duration_sec: durationSec,
			burpee_count: warmupReps,
			sec_per_burpee: secPerBurpee,
			label: "Warmup Round 1",
		},
		{
			type: "warmup_rest",
			duration_sec: 120,
			burpee_count: null,
			sec_per_burpee: null,
			label: "Warmup Rest",
		},
		{
			type: "warmup_burpee",
			duration_sec: durationSec,
			burpee_count: warmupReps,
			sec_per_burpee: secPerBurpee,
			label: "Warmup Round 2",
		},
		{
			type: "warmup_rest",
			duration_sec: 180,
			burpee_count: null,
			sec_per_burpee: null,
			label: "Warmup Rest",
		},
	];
}

export function timelineBurpeeCount(timeline) {
	return timeline.reduce((total, event) => {
		if (event.type !== "work_burpee" && event.type !== "warmup_burpee") return total;
		return total + (event.burpee_count || 0);
	}, 0);
}

function blockTimeline(block) {
	if ((block.repeat_count || 0) <= 0) return [];

	const sets = sortedSets(block);
	const events = [];

	for (let round = 1; round <= block.repeat_count; round++) {
		sets.forEach((set, index) => {
			events.push({
				type: "work_burpee",
				duration_sec: set.burpee_count * set.sec_per_rep,
				burpee_count: set.burpee_count,
				sec_per_burpee: set.sec_per_rep,
				label: `Block ${block.position}`,
			});

			if ((set.end_of_set_rest || 0) > 0 && index + 1 <= sets.length) {
				events.push({
					type: "work_rest",
					duration_sec: set.end_of_set_rest,
					burpee_count: null,
					sec_per_burpee: null,
					label: "Rest",
				});
			}
		});
	}

	return events;
}

function sortedBlocks(plan) {
	return [...(plan?.blocks || [])].sort((a, b) => (a.position || 0) - (b.position || 0));
}

function sortedSets(block) {
	return [...(block?.sets || [])].sort((a, b) => (a.position || 0) - (b.position || 0));
}
