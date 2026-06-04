export function setGlyphBlocksFromPlan(plan) {
	return (plan?.blocks || [])
		.toSorted((a, b) => (a.position || 0) - (b.position || 0))
		.map((block) => ({
			setCount: (block.sets || []).length * (block.repeat_count || 1),
			completedSets: 0,
			currentSetProgress: null,
		}));
}

export function setGlyphBlocksFromFrame(
	plan,
	{
		completedSetCount = 0,
		currentSetIndex = null,
		currentSetProgress = null,
	} = {},
) {
	let firstSetIndex = 0;

	return setGlyphBlocksFromPlan(plan).map((block) => {
		const blockFirstSetIndex = firstSetIndex;
		const blockLastSetIndex = blockFirstSetIndex + block.setCount - 1;
		firstSetIndex += block.setCount;

		const completedSets = Math.max(
			Math.min(completedSetCount - blockFirstSetIndex, block.setCount),
			0,
		);
		const hasCurrentSet =
			Number.isInteger(currentSetIndex) &&
			currentSetIndex >= blockFirstSetIndex &&
			currentSetIndex <= blockLastSetIndex;

		return {
			...block,
			completedSets,
			currentSetProgress: hasCurrentSet ? currentSetProgress : null,
		};
	});
}
