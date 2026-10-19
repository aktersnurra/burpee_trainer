import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";

import {
	initialBurpeeHsmmState,
	stepBurpeeHsmm,
} from "./pose_burpee_hsmm.mjs";

// Every pose sample the camera recorded in a real 20-minute six-count session, in order.
const sessions = [
	// Steady: 140 reps logged, every set on time.
	{ file: "pose_burpee_session_140_reps.json.gz", reps: 140, kind: "a steady session" },
	// Messy: 150 planned, slipped from the middle, with a pause of about 2.5 minutes. The
	// athlete logged 131 by hand and thinks 135 is right.
	{ file: "pose_burpee_session_135_reps.json.gz", reps: 135, kind: "a session that slipped" },
];

for (const { file, reps, kind } of sessions) {
	test(`${kind} counts exactly its ${reps} reps`, () => {
		const fixture = JSON.parse(
			gunzipSync(readFileSync(new URL(`./fixtures/${file}`, import.meta.url))),
		);

		let state = initialBurpeeHsmmState();
		for (const sample of fixture.samples) {
			state = stepBurpeeHsmm(state, sample.features).state;
		}

		assert.equal(state.cadenceMs.length, reps);
	});
}
