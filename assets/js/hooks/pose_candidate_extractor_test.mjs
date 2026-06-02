import test from "node:test";
import assert from "node:assert/strict";
import { extractBurpeeCandidates } from "./pose_candidate_extractor.mjs";

test("extracts completed top-descend-bottom-rise-top loop", () => {
	const candidates = extractBurpeeCandidates({
		score: 10,
		segments: [
			{ phase: "top_anchor", startMs: 0, endMs: 300 },
			{ phase: "descending", startMs: 400, endMs: 900 },
			{ phase: "bottom", startMs: 1000, endMs: 1800 },
			{ phase: "rising", startMs: 1900, endMs: 2600 },
			{ phase: "top_anchor", startMs: 2700, endMs: 3100 },
		],
	});

	assert.equal(candidates.length, 1);
	assert.deepEqual(candidates[0], {
		id: "rep-0-3100",
		startMs: 0,
		endMs: 3100,
		durationMs: 3100,
		variant: "six_count",
		hmmScore: 10,
		phaseBoundaries: {
			startTopAnchorMs: 0,
			descendingStartMs: 400,
			bottomStartMs: 1000,
			risingStartMs: 1900,
			endTopAnchorMs: 2700,
		},
		diagnostics: {
			visibleFractionMean: null,
			occlusionFraction: null,
			rejectReasons: [],
		},
	});
});

test("does not extract incomplete loop", () => {
	const candidates = extractBurpeeCandidates({
		score: 5,
		segments: [
			{ phase: "top_anchor", startMs: 0, endMs: 300 },
			{ phase: "descending", startMs: 400, endMs: 900 },
			{ phase: "bottom", startMs: 1000, endMs: 1800 },
		],
	});

	assert.deepEqual(candidates, []);
});

test("rejects loops outside duration bounds", () => {
	const candidates = extractBurpeeCandidates({
		score: 5,
		segments: [
			{ phase: "top_anchor", startMs: 0, endMs: 100 },
			{ phase: "descending", startMs: 100, endMs: 200 },
			{ phase: "bottom", startMs: 200, endMs: 300 },
			{ phase: "rising", startMs: 300, endMs: 400 },
			{ phase: "top_anchor", startMs: 400, endMs: 500 },
		],
	});

	assert.deepEqual(candidates, []);
});
