import assert from "node:assert/strict";
import test from "node:test";

import { flowTransition, initialFlowState } from "./session_flow_fsm.mjs";

const step = (state, event) => flowTransition(state, event);

function readyCameraState() {
	let state = initialFlowState();
	state = step(state, { type: "SESSION_READY", workoutTimeline: [] }).state;
	state = step(state, { type: "CHOOSE_CAMERA" }).state;
	state = step(state, { type: "CAMERA_STARTED" }).state;
	return step(state, { type: "CAMERA_READINESS", readiness: "ready" }).state;
}

function cameraRunningState() {
	return {
		...initialFlowState(),
		mode: "workout_running",
		captureMode: "camera",
		trackingTrust: "observing",
	};
}

test("camera choice starts locally and startup failure has explicit recovery", () => {
	let result = step(initialFlowState(), {
		type: "SESSION_READY",
		workoutTimeline: [],
	});
	assert.equal(result.state.mode, "capture_choice");

	result = step(result.state, { type: "CHOOSE_CAMERA" });
	assert.equal(result.state.mode, "camera_starting");
	assert.deepEqual(result.commands, [
		{ type: "startCamera" },
		{ type: "renderFlow" },
	]);

	result = step(result.state, {
		type: "CAMERA_START_FAILED",
		reason: "permission_denied",
	});
	assert.equal(result.state.mode, "camera_error");
	assert.equal(result.state.camera.reason, "permission_denied");
});

test("camera confirmation is ignored until readiness is valid", () => {
	let state = initialFlowState();
	state = step(state, { type: "SESSION_READY", workoutTimeline: [] }).state;
	state = step(state, { type: "CHOOSE_CAMERA" }).state;
	state = step(state, { type: "CAMERA_STARTED" }).state;

	const ignored = step(state, {
		type: "GESTURE_CONFIRM",
		step: "camera_setup",
	});
	assert.equal(ignored.state.mode, "camera_setup");
	assert.deepEqual(ignored.commands, []);

	const accepted = step(readyCameraState(), {
		type: "GESTURE_CONFIRM",
		step: "camera_setup",
	});
	assert.equal(accepted.state.mode, "warmup_choice");
});

test("warmup timeout pauses on readiness loss and ignores stale expiry", () => {
	let state = readyCameraState();
	state = step(state, {
		type: "GESTURE_CONFIRM",
		step: "camera_setup",
	}).state;

	const lost = step(state, {
		type: "CAMERA_READINESS",
		readiness: "not_ready",
	});
	assert.deepEqual(lost.commands, [
		{ type: "pauseWarmupTimeout" },
		{ type: "renderFlow" },
	]);

	const stillLost = step(lost.state, {
		type: "CAMERA_READINESS",
		readiness: "not_ready",
	});
	assert.deepEqual(stillLost.commands, [{ type: "renderFlow" }]);

	const stale = step(stillLost.state, {
		type: "WARMUP_TIMEOUT",
		step: "warmup",
	});
	assert.equal(stale.state.mode, "warmup_choice");
	assert.deepEqual(stale.commands, []);
});

test("camera completion pre-fills detected count after absent frames", () => {
	const result = step(cameraRunningState(), {
		type: "SEGMENT_FINISHED",
		result: {
			burpeeCountDone: 99,
			scheduledRepsDone: 5,
			detectedReps: 4,
			detectedDurationSec: 42,
			cadenceMs: [8_000, 18_000, 29_000, 42_000],
		},
	});

	assert.equal(result.state.completion.scheduledRepsDone, 5);
	assert.equal(result.state.completion.burpeeCountActual, 4);
	assert.equal(
		result.state.completion.burpeeCountProvenance,
		"camera_confirmed",
	);
	assert.equal(result.state.completion.durationSecActual, 42);
	assert.equal(result.state.completion.trackingTrust, "finished");
	assert.deepEqual(
		result.state.completion.cadenceMs,
		[8_000, 18_000, 29_000, 42_000],
	);
});

test("explicit work durations plan 38 seconds while actual counts remain camera-only", () => {
	const explicitTimeline = [
		{
			kind: "work",
			reps: 2,
			sec_per_rep: 10,
			sec_per_burpee: 3,
			duration_sec: 20,
		},
		{ kind: "rest", duration_sec: 5 },
		{
			kind: "work",
			reps: 2,
			sec_per_rep: 10,
			sec_per_burpee: 3,
			duration_sec: 13,
		},
	];
	const legacyTimeline = [
		{ kind: "work", reps: 2, sec_per_rep: 10, sec_per_burpee: 3 },
		{ kind: "rest", duration_sec: 5 },
		{ kind: "work", reps: 2, sec_per_rep: 10, sec_per_burpee: 3 },
	];

	const noCamera = step(
		{
			...initialFlowState(),
			mode: "workout_running",
			captureMode: "no_camera",
			workoutTimeline: explicitTimeline,
		},
		{
			type: "SESSION_DONE",
			result: { burpeeCountDone: 4, scheduledRepsDone: 4, durationSec: 38 },
		},
	);
	assert.equal(noCamera.state.completion.durationSecPlanned, 38);
	assert.equal(noCamera.state.completion.scheduledRepsDone, 4);
	assert.equal(noCamera.state.completion.burpeeCountActual, 4);
	assert.equal(noCamera.state.completion.burpeeCountProvenance, "scheduled");

	const camera = step(
		{
			...cameraRunningState(),
			workoutTimeline: explicitTimeline,
		},
		{
			type: "SEGMENT_FINISHED",
			result: {
				burpeeCountDone: 4,
				scheduledRepsDone: 4,
				detectedReps: 0,
				detectedDurationSec: 38,
			},
		},
	);
	assert.equal(camera.state.completion.scheduledRepsDone, 4);
	assert.equal(camera.state.completion.burpeeCountActual, 0);
	assert.equal(
		camera.state.completion.burpeeCountProvenance,
		"camera_confirmed",
	);

	const legacy = step(
		{
			...initialFlowState(),
			mode: "workout_running",
			workoutTimeline: legacyTimeline,
		},
		{ type: "SESSION_DONE", result: { scheduledRepsDone: 4, durationSec: 45 } },
	);
	assert.equal(legacy.state.completion.durationSecPlanned, 45);
});

test("restored completion draft enters review without replaying workout", () => {
	const restored = step(
		step(initialFlowState(), {
			type: "SESSION_READY",
			workoutTimeline: [{ kind: "work", reps: 10, sec_per_rep: 5 }],
		}).state,
		{
			type: "RESTORE_COMPLETION_DRAFT",
			captureMode: "camera",
			completion: {
				burpeeCountActual: 9,
				burpeeCountPlanned: 10,
				durationSecActual: 52,
				durationSecPlanned: 50,
				detectedReps: 9,
				detectedDurationSec: 52,
				trackingTrust: "finished",
				cadenceMs: [5_000, 10_000],
				mood: 1,
				tags: ["great_energy"],
				notePost: "Strong finish",
			},
		},
	);

	assert.equal(restored.state.mode, "completion_review");
	assert.equal(restored.state.captureMode, "camera");
	assert.equal(restored.state.trackingTrust, "finished");
	assert.equal(restored.state.completion.notePost, "Strong finish");
	assert.deepEqual(restored.commands, [
		{ type: "showCompletion", restored: true },
	]);
});

test("acknowledged server completion freezes the exact submitted facts", () => {
	const completion = {
		burpeeCountActual: 10,
		burpeeCountPlanned: 10,
		durationSecActual: 55,
		durationSecPlanned: 50,
		mood: 1,
		tags: ["great_energy"],
		notePost: "Acknowledged",
	};
	const review = {
		...initialFlowState(),
		mode: "completion_review",
		completion: { ...completion, notePost: "editable" },
		saveStatus: "saving",
	};

	const acknowledged = step(review, {
		type: "SERVER_COMPLETION_ACKNOWLEDGED",
		completion,
	}).state;
	const forgedEdit = step(acknowledged, {
		type: "COMPLETION_EDITED",
		changes: {
			burpeeCountActual: 999,
			durationSecActual: 999,
			mood: -1,
			tags: ["tired"],
			notePost: "not acknowledged",
		},
	});

	assert.equal(acknowledged.completionLocked, true);
	assert.deepEqual(acknowledged.completion, completion);
	assert.deepEqual(forgedEdit.commands, []);
	assert.equal(forgedEdit.state, acknowledged);
});

test("completion edits only change approved draft fields", () => {
	const completed = step(
		{
			...initialFlowState(),
			mode: "workout_running",
			captureMode: "camera",
			trackingTrust: "observing",
			workoutTimeline: [{ kind: "work", reps: 10, sec_per_rep: 5 }],
		},
		{
			type: "SESSION_DONE",
			result: {
				burpeeCountDone: 9,
				durationSec: 52,
				detectedReps: 8,
				detectedDurationSec: 49,
				cadenceMs: [6100, 6200],
			},
		},
	).state;
	const completedReview = step(completed, {
		type: "REPORT_PENDING_ACKNOWLEDGED",
	}).state;

	const result = step(completedReview, {
		type: "COMPLETION_EDITED",
		changes: {
			burpeeCountActual: 10,
			durationSecActual: 55,
			burpeeCountPlanned: 999,
			durationSecPlanned: 999,
			trackingTrust: "degraded",
			detectedReps: 999,
			detectedDurationSec: 999,
			cadenceMs: [1],
			mood: 1,
			tags: ["great_energy"],
			contextLowEnergy: true,
			contextHighEnergy: false,
			contextHeatAffected: true,
			primaryLimiter: "legs",
			preferenceFeedback: "avoid",
			notePost: "Strong finish",
		},
	});

	assert.deepEqual(result.state.completion, {
		scheduledRepsDone: 9,
		burpeeCountActual: 10,
		burpeeCountProvenance: "manual",
		burpeeCountPlanned: 10,
		durationSecActual: 55,
		durationSecPlanned: 50,
		detectedReps: 8,
		detectedDurationSec: 49,
		trackingTrust: "observing",
		cadenceMs: [6100, 6200],
		mood: 1,
		tags: ["great_energy"],
		contextLowEnergy: true,
		contextHighEnergy: false,
		contextHeatAffected: true,
		primaryLimiter: "legs",
		preferenceFeedback: "avoid",
		notePost: "Strong finish",
	});
});
