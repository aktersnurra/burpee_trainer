const MIN_REP_MS = 2000;
const MAX_REP_MS = 16000;
const LOOP = Object.freeze([
	"top_anchor",
	"descending",
	"bottom",
	"rising",
	"top_anchor",
]);

export function extractBurpeeCandidates(decoded) {
	const segments = decoded?.segments || [];
	const candidates = [];

	for (let index = 0; index <= segments.length - LOOP.length; index++) {
		const window = segments.slice(index, index + LOOP.length);
		if (!matchesLoop(window)) continue;

		const candidate = candidateFromWindow(window, decoded.score ?? 0);
		if (
			candidate.durationMs < MIN_REP_MS ||
			candidate.durationMs > MAX_REP_MS
		) {
			continue;
		}
		candidates.push(candidate);
	}

	return candidates;
}

function matchesLoop(segments) {
	return LOOP.every((phase, index) => segments[index]?.phase === phase);
}

function candidateFromWindow(segments, hmmScore) {
	const [startTop, descending, bottom, rising, endTop] = segments;
	const startMs = startTop.startMs;
	const endMs = endTop.endMs;
	const durationMs = endMs - startMs;

	return {
		id: `rep-${startMs}-${endMs}`,
		startMs,
		endMs,
		durationMs,
		variant: durationMs <= 8000 ? "six_count" : "navy_seal",
		hmmScore,
		phaseBoundaries: {
			startTopAnchorMs: startTop.startMs,
			descendingStartMs: descending.startMs,
			bottomStartMs: bottom.startMs,
			risingStartMs: rising.startMs,
			endTopAnchorMs: endTop.startMs,
		},
		diagnostics: {
			visibleFractionMean: null,
			occlusionFraction: null,
			rejectReasons: [],
		},
	};
}
