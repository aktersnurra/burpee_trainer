import test from "node:test";
import assert from "node:assert/strict";
import { setGlyphBlocksFromFrame } from "./session_set_glyphs.mjs";

function planWithBlockSetCounts(setCounts) {
	return {
		blocks: setCounts.map((count, blockIndex) => ({
			position: blockIndex + 1,
			repeat_count: 1,
			sets: Array.from({ length: count }, (_, setIndex) => ({
				position: setIndex + 1,
			})),
		})),
	};
}

test("maps absolute set frame progress into grouped glyph blocks", () => {
	const blocks = setGlyphBlocksFromFrame(planWithBlockSetCounts([3, 3, 2]), {
		completedSetCount: 4,
		currentSetIndex: 4,
		currentSetProgress: 0.5,
	});

	assert.deepEqual(blocks, [
		{ setCount: 3, completedSets: 3, currentSetProgress: null },
		{ setCount: 3, completedSets: 1, currentSetProgress: 0.5 },
		{ setCount: 2, completedSets: 0, currentSetProgress: null },
	]);
});

test("keeps rest frames on completed sets without current fill", () => {
	const blocks = setGlyphBlocksFromFrame(planWithBlockSetCounts([2, 2]), {
		completedSetCount: 1,
		currentSetIndex: null,
		currentSetProgress: null,
	});

	assert.deepEqual(blocks, [
		{ setCount: 2, completedSets: 1, currentSetProgress: null },
		{ setCount: 2, completedSets: 0, currentSetProgress: null },
	]);
});

test("honors block repeat counts when counting sets", () => {
	const plan = {
		blocks: [
			{
				position: 1,
				repeat_count: 2,
				sets: [{ position: 1 }, { position: 2 }],
			},
		],
	};

	assert.deepEqual(
		setGlyphBlocksFromFrame(plan, {
			completedSetCount: 2,
			currentSetIndex: 2,
			currentSetProgress: 0.25,
		}),
		[{ setCount: 4, completedSets: 2, currentSetProgress: 0.25 }],
	);
});
