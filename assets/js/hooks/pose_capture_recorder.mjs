const DEFAULT_FLUSH_INTERVAL_MS = 3000;
export const MAX_TRACE_CHUNK_BYTES = 200_000;

export function serializedJsonBytes(value) {
	return new TextEncoder().encode(JSON.stringify(value)).byteLength;
}

export function initialPoseCaptureRecorder(options = {}) {
	return {
		flushIntervalMs: options.flushIntervalMs || DEFAULT_FLUSH_INTERVAL_MS,
		nextChunkIndex: 0,
		pendingSegment: null,
		pendingStartedAtMs: null,
		pendingSamples: [],
		diagnostics: [],
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

	const candidateSamples = [...current.pendingSamples, sample];

	if (serializedJsonBytes(payloadFor(candidateSamples)) >= MAX_TRACE_CHUNK_BYTES) {
		if (current.pendingSamples.length > 0) {
			const flushed = flushPending(current);
			current = flushed.state;
			chunks.push(flushed.chunk);
		}

		if (serializedJsonBytes(payloadFor([sample])) >= MAX_TRACE_CHUNK_BYTES) {
			return {
				state: {
					...current,
					diagnostics: [
						...current.diagnostics,
						{ type: "sample_exceeds_chunk_byte_budget", tMs: sample.tMs },
					],
				},
				chunks,
			};
		}
	}

	const pendingStartedAtMs =
		current.pendingSamples.length === 0
			? sample.tMs
			: current.pendingStartedAtMs;

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

function payloadFor(samples) {
	return {
		version: 1,
		samples,
	};
}

function flushPending(state) {
	const samples = state.pendingSamples;
	const chunk = {
		segment: state.pendingSegment,
		chunk_index: state.nextChunkIndex,
		started_at_ms: state.pendingStartedAtMs,
		ended_at_ms: samples[samples.length - 1].tMs,
		sample_count: samples.length,
		payload: payloadFor(samples),
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
