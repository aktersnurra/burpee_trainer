const MIN_TEMPLATE_SAMPLES = 3;
const MIN_SIGNAL_RANGE = 0.12;
const MIN_CLOSENESS_RANGE = 0.12;
const MATCH_DISTANCE_LIMIT = 0.18;
const TRIM_RECOVERY_RATIO = 0.5;

export function initialTemplateMatcherState() {
	return { samples: [] };
}

export function recordTemplateSample(state, sample) {
	return { samples: [...state.samples, sample] };
}

export function finishTemplateRecording(state) {
	const samples = state.samples.filter((sample) => sample.confidence >= 0.5);

	if (samples.length < MIN_TEMPLATE_SAMPLES) {
		return { ok: false, reason: "too_few_samples" };
	}

	const ranges = channelRanges(samples);
	if (!hasEnoughMotion(ranges)) {
		return { ok: false, reason: "low_motion" };
	}

	const trimmedSamples = trimRepSamples(samples, ranges);
	const trimmedRanges = channelRanges(trimmedSamples);
	if (trimmedSamples.length < MIN_TEMPLATE_SAMPLES || !hasEnoughMotion(trimmedRanges)) {
		return { ok: false, reason: "low_motion" };
	}

	return {
		ok: true,
		template: {
			points: normalizeSamples(trimmedSamples, trimmedRanges),
			durationMs: trimmedSamples.at(-1).tMs - trimmedSamples[0].tMs,
			sourceStartTMs: trimmedSamples[0].tMs,
			sourceEndTMs: trimmedSamples.at(-1).tMs,
		},
	};
}

export function matchTemplateWindow(template, samples) {
	const visibleSamples = samples.filter((sample) => sample.confidence >= 0.5);

	if (
		!template?.points?.length ||
		visibleSamples.length < MIN_TEMPLATE_SAMPLES
	) {
		return { ok: false, reason: "too_few_samples" };
	}

	const ranges = channelRanges(visibleSamples);
	const points = normalizeSamples(visibleSamples, ranges);
	const distance = dynamicTimeWarpingDistance(template.points, points);

	if (distance > MATCH_DISTANCE_LIMIT) {
		return { ok: false, reason: "distance", distance };
	}

	const downSample = visibleSamples.reduce((best, sample) =>
		downScore(sample) > downScore(best) ? sample : best,
	);
	const upSample = visibleSamples.at(-1);

	return {
		ok: true,
		distance,
		downTMs: downSample.tMs,
		upTMs: upSample.tMs,
	};
}

function trimRepSamples(samples, ranges) {
	const downIndex = samples.reduce(
		(bestIndex, sample, index) =>
			downScore(sample) > downScore(samples[bestIndex]) ? index : bestIndex,
		0,
	);
	const signalRecovery = ranges.signal.min + ranges.signal.range * TRIM_RECOVERY_RATIO;
	const closenessRecovery = ranges.closeness.max - ranges.closeness.range * TRIM_RECOVERY_RATIO;

	let startIndex = 0;
	for (let index = downIndex - 1; index >= 0; index--) {
		const sample = samples[index];
		if (sample.signal >= signalRecovery || (sample.closeness ?? 0) <= closenessRecovery) {
			startIndex = index;
			break;
		}
	}

	let endIndex = samples.length - 1;
	for (let index = downIndex + 1; index < samples.length; index++) {
		const sample = samples[index];
		if (sample.signal >= signalRecovery || (sample.closeness ?? 0) <= closenessRecovery) {
			endIndex = index;
			break;
		}
	}

	return samples.slice(startIndex, endIndex + 1);
}

function hasEnoughMotion(ranges) {
	return (
		ranges.signal.range >= MIN_SIGNAL_RANGE ||
		ranges.closeness.range >= MIN_CLOSENESS_RANGE
	);
}

function normalizeSamples(samples, ranges) {
	const firstTMs = samples[0].tMs;
	const durationMs = Math.max(1, samples.at(-1).tMs - firstTMs);

	return samples.map((sample) => ({
		t: round2((sample.tMs - firstTMs) / durationMs),
		signal: round2(normalizeChannel(sample.signal, ranges.signal)),
		closeness: round2(
			normalizeChannel(sample.closeness ?? 0, ranges.closeness),
		),
	}));
}

function channelRanges(samples) {
	return {
		signal: rangeFor(samples.map((sample) => sample.signal)),
		closeness: rangeFor(samples.map((sample) => sample.closeness ?? 0)),
	};
}

function rangeFor(values) {
	const min = Math.min(...values);
	const max = Math.max(...values);
	return { min, max, range: max - min };
}

function normalizeChannel(value, range) {
	if (range.range === 0) return 0;
	return (value - range.min) / range.range;
}

function dynamicTimeWarpingDistance(templatePoints, samplePoints) {
	const rowCount = templatePoints.length + 1;
	const columnCount = samplePoints.length + 1;
	const costs = Array.from({ length: rowCount }, () =>
		Array(columnCount).fill(Infinity),
	);
	costs[0][0] = 0;

	for (let row = 1; row < rowCount; row++) {
		for (let column = 1; column < columnCount; column++) {
			const cost = pointDistance(
				templatePoints[row - 1],
				samplePoints[column - 1],
			);
			costs[row][column] =
				cost +
				Math.min(
					costs[row - 1][column],
					costs[row][column - 1],
					costs[row - 1][column - 1],
				);
		}
	}

	return (
		costs[templatePoints.length][samplePoints.length] /
		(templatePoints.length + samplePoints.length)
	);
}

function pointDistance(a, b) {
	const signal = a.signal - b.signal;
	const closeness = a.closeness - b.closeness;
	return Math.sqrt(signal * signal + closeness * closeness);
}

function downScore(sample) {
	return (sample.closeness ?? 0) - sample.signal;
}

function round2(value) {
	return Math.round(value * 100) / 100;
}
