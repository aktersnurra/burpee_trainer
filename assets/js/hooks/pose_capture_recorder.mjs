const DEFAULT_FLUSH_INTERVAL_MS = 3000;

export function initialPoseCaptureRecorder(options = {}) {
	return {
		flushIntervalMs: options.flushIntervalMs || DEFAULT_FLUSH_INTERVAL_MS,
		nextChunkIndex: 0,
		pendingSegment: null,
		pendingStartedAtMs: null,
		pendingSamples: [],
	};
}

export function recordPoseSample(state, sample, { segment, nowMs }) {
	let current = state;
	const chunks = [];

	if (current.pendingSamples.length > 0 && current.pendingSegment !== segment) {
		const flushed = flushPending(current);
		current = flushed.state;
		chunks.push(flushed.chunk);
	}

	const pendingStartedAtMs =
		current.pendingSamples.length === 0 ? sample.tMs : current.pendingStartedAtMs;

	current = {
		...current,
		pendingSegment: segment,
		pendingStartedAtMs,
		pendingSamples: [...current.pendingSamples, sample],
	};

	if (
		current.pendingSamples.length > 0 &&
		nowMs - current.pendingStartedAtMs >= current.flushIntervalMs
	) {
		const flushed = flushPending(current);
		current = flushed.state;
		chunks.push(flushed.chunk);
	}

	return { state: current, chunks };
}

export function flushPoseCaptureRecorder(state, _options = {}) {
	if (state.pendingSamples.length === 0) {
		return { state, chunks: [] };
	}

	const flushed = flushPending(state);
	return { state: flushed.state, chunks: [flushed.chunk] };
}

function flushPending(state) {
	const samples = state.pendingSamples;
	const chunk = {
		segment: state.pendingSegment,
		chunk_index: state.nextChunkIndex,
		started_at_ms: state.pendingStartedAtMs,
		ended_at_ms: samples[samples.length - 1].tMs,
		sample_count: samples.length,
		payload: {
			version: 1,
			samples,
		},
	};

	return {
		chunk,
		state: {
			...state,
			nextChunkIndex: state.nextChunkIndex + 1,
			pendingSegment: null,
			pendingStartedAtMs: null,
			pendingSamples: [],
		},
	};
}
