export const BURPEE_PHASES = Object.freeze([
	"unknown",
	"top_anchor",
	"rest_standing",
	"descending",
	"bottom",
	"rising",
]);

export function scorePhaseEmissions(frame) {
	const scores = {
		unknown: 0,
		top_anchor: 0,
		rest_standing: 0,
		descending: 0,
		bottom: 0,
		rising: 0,
	};

	const confidence = finiteOr(frame.poseConfidence ?? frame.confidence, 0);
	const visibleFraction = finiteOr(frame.visibleFraction, 0);
	const signal = finiteOr(frame.signal, 0.5);
	const closeness = finiteOr(frame.closeness, 0);
	const noseY = finiteOr(frame.noseY, 0.5);
	const shoulderY = finiteOr(frame.shoulderMidY, 0.5);
	const hipY = finiteOr(frame.hipMidY, 0.5);
	const kneeScore = finiteOr(frame.kneeScore, 0);
	const footScore = finiteOr(frame.footScore ?? frame.ankleScore, 0);
	const upperBodyScore = finiteOr(frame.upperBodyScore, confidence);
	const dNoseY = finiteOr(frame.dNoseY, 0);
	const dShoulderY = finiteOr(frame.dShoulderY, 0);
	const dHipY = finiteOr(frame.dHipY, 0);
	const dSignal = finiteOr(frame.dSignal, 0);
	const dCloseness = finiteOr(frame.dCloseness, 0);
	const meanDownVelocity = (dNoseY + dShoulderY + dHipY) / 3;
	const meanUpVelocity = -meanDownVelocity;

	scores.unknown += low(confidence, 0.35) * 2.2;
	scores.unknown += low(visibleFraction, 0.25) * 2.2;
	scores.unknown += frame.isOccluded ? 0.4 : 0;

	scores.top_anchor += high(confidence, 0.65) * 0.8;
	scores.top_anchor += high(upperBodyScore, 0.65) * 0.8;
	scores.top_anchor += low(noseY, 0.28) * 1.2;
	scores.top_anchor += low(shoulderY, 0.38) * 1.2;
	scores.top_anchor += band(hipY, 0.35, 0.65) * 0.7;
	scores.top_anchor += high(signal, 0.45) * 0.7;
	scores.top_anchor += low(Math.abs(meanDownVelocity), 0.25) * 0.3;

	scores.rest_standing = scores.top_anchor - 0.6;
	scores.rest_standing += low(Math.abs(meanDownVelocity), 0.12) * 0.2;

	scores.descending += high(meanDownVelocity, 0.35) * 1.8;
	scores.descending += high(dNoseY, 0.35) * 0.5;
	scores.descending += high(dShoulderY, 0.35) * 0.5;
	scores.descending += low(dSignal, -0.25) * 1.0;
	scores.descending += high(dCloseness, 0.15) * 0.5;
	scores.descending += band(shoulderY, 0.32, 0.7) * 0.3;

	scores.bottom += low(signal, 0.18) * 1.4;
	scores.bottom += high(closeness, 0.65) * 0.8;
	scores.bottom += high(noseY, 0.75) * 0.9;
	scores.bottom += high(shoulderY, 0.75) * 0.7;
	scores.bottom += high(hipY, 0.85) * 0.7;
	scores.bottom += low(kneeScore, 0.35) * 0.5;
	scores.bottom += low(footScore, 0.35) * 0.5;
	scores.bottom += frame.isOccluded ? 0.3 : 0;
	scores.bottom += low(confidence, 0.65) * 0.2;

	scores.rising += high(meanUpVelocity, 0.35) * 1.8;
	scores.rising += low(dNoseY, -0.35) * 0.5;
	scores.rising += low(dShoulderY, -0.35) * 0.5;
	scores.rising += high(dSignal, 0.25) * 1.0;
	scores.rising += low(dCloseness, -0.15) * 0.5;
	scores.rising += band(shoulderY, 0.32, 0.75) * 0.3;

	return Object.fromEntries(
		BURPEE_PHASES.map((phase) => [phase, round4(scores[phase])]),
	);
}

function high(value, threshold) {
	return clamp01((value - threshold) / Math.max(1 - threshold, 0.0001));
}

function low(value, threshold) {
	return clamp01((threshold - value) / Math.max(threshold, 0.0001));
}

function band(value, min, max) {
	if (value < min) return clamp01(1 - (min - value) / Math.max(min, 0.0001));
	if (value > max) return clamp01(1 - (value - max) / Math.max(1 - max, 0.0001));
	return 1;
}

function finiteOr(value, fallback) {
	return Number.isFinite(value) ? value : fallback;
}

function clamp01(value) {
	if (value < 0) return 0;
	if (value > 1) return 1;
	return value;
}

function round4(value) {
	const rounded = Math.round(value * 10000) / 10000;
	return Object.is(rounded, -0) ? 0 : rounded;
}
