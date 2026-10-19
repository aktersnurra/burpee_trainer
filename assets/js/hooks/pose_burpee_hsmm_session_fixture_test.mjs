import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";

import {
	initialBurpeeHsmmState,
	stepBurpeeHsmm,
} from "./pose_burpee_hsmm.mjs";

// Every pose sample the camera recorded in one real 20-minute six-count session, in order.
// The athlete logged 140 reps.
const fixture = JSON.parse(
	gunzipSync(
		readFileSync(
			new URL("./fixtures/pose_burpee_session_140_reps.json.gz", import.meta.url),
		),
	),
);

test("a real session counts exactly the reps the athlete logged", () => {
	let state = initialBurpeeHsmmState();
	for (const sample of fixture.samples) {
		state = stepBurpeeHsmm(state, sample.features).state;
	}

	assert.equal(state.cadenceMs.length, fixture.reps_logged);
});
