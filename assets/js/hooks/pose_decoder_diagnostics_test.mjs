import test from "node:test";
import assert from "node:assert/strict";
import { formatDecoderDiagnostics } from "./pose_decoder_diagnostics.mjs";

test("formats empty decoder diagnostics", () => {
	assert.deepEqual(formatDecoderDiagnostics(null, []), {
		phase: "—",
		candidateCount: "0",
		illegalTransitions: "0",
		maxUnknown: "0ms",
		segments: "[]",
	});
});

test("formats current phase, candidate count, and compact segments", () => {
	const diagnostics = formatDecoderDiagnostics(
		{
			segments: [
				{ phase: "top_anchor", startMs: 0, endMs: 300 },
				{ phase: "descending", startMs: 400, endMs: 900 },
			],
			diagnostics: { illegalTransitionCount: 2, maxUnknownMs: 200 },
		},
		[{ id: "rep-0-3100" }],
	);

	assert.deepEqual(diagnostics, {
		phase: "descending",
		candidateCount: "1",
		illegalTransitions: "2",
		maxUnknown: "200ms",
		segments: "top_anchor:0-300 | descending:400-900",
	});
});
