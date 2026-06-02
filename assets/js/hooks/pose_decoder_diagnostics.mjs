export function formatDecoderDiagnostics(decoded, candidates) {
	const segments = decoded?.segments || [];
	const latestSegment = segments.at(-1);
	const diagnostics = decoded?.diagnostics || {};

	return {
		phase: latestSegment?.phase || "—",
		candidateCount: String(candidates?.length || 0),
		illegalTransitions: String(diagnostics.illegalTransitionCount || 0),
		maxUnknown: `${diagnostics.maxUnknownMs || 0}ms`,
		segments: formatSegments(segments),
	};
}

function formatSegments(segments) {
	if (!segments || segments.length === 0) return "[]";
	return segments
		.slice(-8)
		.map((segment) => `${segment.phase}:${segment.startMs}-${segment.endMs}`)
		.join(" | ");
}
