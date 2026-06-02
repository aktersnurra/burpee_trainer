import test from "node:test";
import assert from "node:assert/strict";
import { scorePhaseEmissions } from "./pose_phase_emissions.mjs";

function frame(overrides = {}) {
	return {
		tMs: 1000,
		poseConfidence: 0.9,
		visibleFraction: 0.8,
		isOccluded: false,
		signal: 0.7,
		closeness: 0.35,
		noseY: 0.16,
		shoulderMidY: 0.28,
		hipMidY: 0.52,
		kneeMidY: 0.72,
		ankleMidY: 0.9,
		wristMidY: 0.45,
		footMidY: 0.92,
		upperBodyScore: 0.9,
		handScore: 0.8,
		hipScore: 0.9,
		kneeScore: 0.75,
		footScore: 0.65,
		dNoseY: 0,
		dShoulderY: 0,
		dHipY: 0,
		dSignal: 0,
		dCloseness: 0,
		...overrides,
	};
}

function assertWinner(scores, phase) {
	const winner = Object.entries(scores).sort((a, b) => b[1] - a[1])[0][0];
	assert.equal(winner, phase);
}

test("scores top_anchor highest for high-confidence top posture", () => {
	assertWinner(scorePhaseEmissions(frame()), "top_anchor");
});

test("scores descending highest for downward body motion", () => {
	assertWinner(
		scorePhaseEmissions(
			frame({
				noseY: 0.35,
				shoulderMidY: 0.45,
				hipMidY: 0.62,
				signal: 0.38,
				dNoseY: 1.2,
				dShoulderY: 1.0,
				dHipY: 0.8,
				dSignal: -1.1,
				dCloseness: 0.4,
			}),
		),
		"descending",
	);
});

test("scores bottom highest for compressed low-signal occluded pose", () => {
	assertWinner(
		scorePhaseEmissions(
			frame({
				poseConfidence: 0.45,
				visibleFraction: 0.45,
				isOccluded: true,
				signal: 0.02,
				closeness: 0.82,
				noseY: 0.92,
				shoulderMidY: 0.96,
				hipMidY: 1.05,
				kneeScore: 0.2,
				footScore: 0.15,
			}),
		),
		"bottom",
	);
});

test("scores rising highest for upward recovery from bottom", () => {
	assertWinner(
		scorePhaseEmissions(
			frame({
				noseY: 0.42,
				shoulderMidY: 0.5,
				hipMidY: 0.7,
				signal: 0.35,
				dNoseY: -1.1,
				dShoulderY: -1.0,
				dHipY: -0.8,
				dSignal: 1.2,
				dCloseness: -0.4,
			}),
		),
		"rising",
	);
});

test("scores unknown highest when pose is mostly missing", () => {
	assertWinner(
		scorePhaseEmissions(
			frame({ poseConfidence: 0.05, visibleFraction: 0.08, isOccluded: true }),
		),
		"unknown",
	);
});
