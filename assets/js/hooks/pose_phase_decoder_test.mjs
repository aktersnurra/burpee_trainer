import test from "node:test";
import assert from "node:assert/strict";
import { decodeBurpeePhases } from "./pose_phase_decoder.mjs";

function frame(tMs, phase, overrides = {}) {
	const base = {
		tMs,
		poseConfidence: 0.9,
		visibleFraction: 0.8,
		isOccluded: false,
		signal: 0.7,
		closeness: 0.35,
		noseY: 0.16,
		shoulderMidY: 0.28,
		hipMidY: 0.52,
		upperBodyScore: 0.9,
		kneeScore: 0.75,
		footScore: 0.65,
		dNoseY: 0,
		dShoulderY: 0,
		dHipY: 0,
		dSignal: 0,
		dCloseness: 0,
		...overrides,
	};

	if (phase === "descending") {
		return {
			...base,
			noseY: 0.35,
			shoulderMidY: 0.45,
			hipMidY: 0.62,
			signal: 0.38,
			dNoseY: 1.2,
			dShoulderY: 1.0,
			dHipY: 0.8,
			dSignal: -1.1,
			dCloseness: 0.4,
		};
	}

	if (phase === "bottom") {
		return {
			...base,
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
		};
	}

	if (phase === "rising") {
		return {
			...base,
			noseY: 0.42,
			shoulderMidY: 0.5,
			hipMidY: 0.7,
			signal: 0.35,
			dNoseY: -1.1,
			dShoulderY: -1.0,
			dHipY: -0.8,
			dSignal: 1.2,
			dCloseness: -0.4,
		};
	}

	if (phase === "unknown") {
		return { ...base, poseConfidence: 0.05, visibleFraction: 0.08, isOccluded: true };
	}

	return base;
}

function sequence(parts) {
	let tMs = 0;
	const frames = [];
	for (const [phase, count] of parts) {
		for (let i = 0; i < count; i++) {
			frames.push(frame(tMs, phase));
			tMs += 100;
		}
	}
	return frames;
}

test("decodes legal burpee phase loop into segments", () => {
	const decoded = decodeBurpeePhases(
		sequence([
			["top_anchor", 3],
			["descending", 4],
			["bottom", 5],
			["rising", 4],
			["top_anchor", 3],
		]),
	);

	assert.deepEqual(
		decoded.segments.map((segment) => segment.phase),
		["top_anchor", "descending", "bottom", "rising", "top_anchor"],
	);
	assert.equal(decoded.states.length, 19);
	assert.equal(decoded.segments[0].startMs, 0);
	assert.equal(decoded.segments.at(-1).endMs, 1800);
});

test("bridges short unknown gaps inside legal movement", () => {
	const decoded = decodeBurpeePhases(
		sequence([
			["top_anchor", 2],
			["descending", 2],
			["unknown", 2],
			["bottom", 3],
			["rising", 3],
			["top_anchor", 2],
		]),
	);

	assert.deepEqual(
		decoded.segments.map((segment) => segment.phase),
		["top_anchor", "descending", "unknown", "bottom", "rising", "top_anchor"],
	);
	assert.equal(decoded.diagnostics.maxUnknownMs, 200);
});

test("rejects illegal direct top to bottom jump by inserting unknown diagnostics", () => {
	const decoded = decodeBurpeePhases(
		sequence([
			["top_anchor", 3],
			["bottom", 4],
			["top_anchor", 3],
		]),
	);

	assert.equal(decoded.diagnostics.illegalTransitionCount > 0, true);
});
