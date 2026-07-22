import assert from "node:assert/strict";
import test from "node:test";

import {
	finishTrackingObserver,
	initialTrackingObserver,
	observeTrackingRep,
	startTrackingObserver,
	updateTrackingReadiness,
	updateTrackingStatus,
} from "./pose_tracking_observer.mjs";

function liveReadyObserver() {
	const live = updateTrackingStatus(initialTrackingObserver(), "live");
	return startTrackingObserver(live, "ready");
}

test("eligible work reps produce authoritative cadence", () => {
	let state = liveReadyObserver();
	state = observeTrackingRep(state, {
		index: 1,
		elapsedMs: 2_500,
		eligible: true,
	});
	state = observeTrackingRep(state, {
		index: 2,
		elapsedMs: 5_100,
		eligible: true,
	});

	const finished = finishTrackingObserver(state, 10_000);
	assert.deepEqual(finished.result, {
		trusted: true,
		cadenceMs: [2_500, 5_100],
		reason: null,
	});
});

test("count-in pause and explicit rest candidates are ignored", () => {
	let state = liveReadyObserver();
	state = observeTrackingRep(state, {
		index: 1,
		elapsedMs: 1_000,
		eligible: false,
	});
	assert.deepEqual(state.cadenceMs, []);
	assert.equal(state.mode, "observing");
});

test("feet-limited ready quality remains trustworthy", () => {
	const state = startTrackingObserver(
		updateTrackingStatus(initialTrackingObserver(), "live"),
		"ready",
	);
	assert.equal(state.mode, "observing");
	assert.equal(state.degradedReason, null);
});

test("tracking loss is sticky and forces fallback", () => {
	const lost = updateTrackingStatus(liveReadyObserver(), "lost");
	const recovered = updateTrackingStatus(lost, "live");
	const finished = finishTrackingObserver(recovered, 10_000);
	assert.equal(finished.result.trusted, false);
	assert.equal(finished.result.reason, "tracking_lost");
});

test("core readiness loss after start is sticky", () => {
	const lost = updateTrackingReadiness(liveReadyObserver(), "not_ready");
	const finished = finishTrackingObserver(lost, 10_000);
	assert.equal(finished.result.trusted, false);
	assert.equal(finished.result.reason, "pose_not_ready");
});

test("duplicate index and decreasing timestamp degrade", () => {
	let state = liveReadyObserver();
	state = observeTrackingRep(state, {
		index: 1,
		elapsedMs: 2_500,
		eligible: true,
	});
	state = observeTrackingRep(state, {
		index: 1,
		elapsedMs: 2_600,
		eligible: true,
	});
	assert.equal(finishTrackingObserver(state, 10_000).result.trusted, false);

	state = liveReadyObserver();
	state = observeTrackingRep(state, {
		index: 1,
		elapsedMs: 2_500,
		eligible: true,
	});
	state = observeTrackingRep(state, {
		index: 2,
		elapsedMs: 2_000,
		eligible: true,
	});
	assert.equal(finishTrackingObserver(state, 10_000).result.trusted, false);
});

test("timestamp beyond duration forces fallback", () => {
	let state = liveReadyObserver();
	state = observeTrackingRep(state, {
		index: 1,
		elapsedMs: 10_001,
		eligible: true,
	});
	assert.equal(finishTrackingObserver(state, 10_000).result.trusted, false);
});
