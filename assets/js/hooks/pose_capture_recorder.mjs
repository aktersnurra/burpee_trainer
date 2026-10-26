const DEFAULT_FLUSH_INTERVAL_MS = 3000;
export const MAX_TRACE_CHUNK_BYTES = 200_000;
const PAYLOAD_VERSION = 2;
const EMPTY_PAYLOAD_BYTES = new TextEncoder().encode(
	JSON.stringify({ version: PAYLOAD_VERSION, samples: [], reps: [] }),
).byteLength;

export function serializedJsonBytes(value) {
	return new TextEncoder().encode(JSON.stringify(value)).byteLength;
}

export function initialPoseCaptureRecorder(options = {}) {
	return {
		flushIntervalMs: options.flushIntervalMs || DEFAULT_FLUSH_INTERVAL_MS,
		sampleByteLength: options.sampleByteLength ?? serializedJsonBytes,
		nextChunkIndex: 0,
		pendingSegment: null,
		pendingStartedAtMs: null,
		pendingSamples: [],
		pendingSamplesByteLength: 0,
		pendingReps: [],
		diagnostics: [],
	};
}

// A rep the counter emitted; it travels with the next chunk flushed.
export function recordPoseRep(state, tMs) {
	return { ...state, pendingReps: [...state.pendingReps, tMs] };
}

export function recordPoseSample(state, sample, { segment, nowMs }) {
	let current = state;
	const chunks = [];

	if (current.pendingSamples.length > 0 && current.pendingSegment !== segment) {
		const flushed = flushPending(current);
		current = flushed.state;
		chunks.push(flushed.chunk);
	}

	const sampleByteLength = current.sampleByteLength(sample);
	const candidateSamplesByteLength =
		current.pendingSamplesByteLength +
		(current.pendingSamples.length > 0 ? 1 : 0) +
		sampleByteLength;

	if (payloadByteLength(candidateSamplesByteLength) >= MAX_TRACE_CHUNK_BYTES) {
		if (current.pendingSamples.length > 0) {
			const flushed = flushPending(current);
			current = flushed.state;
			chunks.push(flushed.chunk);
		}

		if (payloadByteLength(sampleByteLength) >= MAX_TRACE_CHUNK_BYTES) {
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
		current.pendingSamples.length === 0 ? sample.tMs : current.pendingStartedAtMs;

	current = {
		...current,
		pendingSegment: segment,
		pendingStartedAtMs,
		pendingSamples: [...current.pendingSamples, sample],
		pendingSamplesByteLength:
			current.pendingSamplesByteLength +
			(current.pendingSamples.length > 0 ? 1 : 0) +
			sampleByteLength,
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

// Version 2: samples hold every frame the counter saw (unusable ones as
// `{ tMs, usable: false }`, resets as `{ tMs, reset: true }`); reps are the rep times it emitted.
function payloadFor(samples, reps) {
	return {
		version: PAYLOAD_VERSION,
		samples,
		reps,
	};
}

function payloadByteLength(samplesByteLength) {
	return EMPTY_PAYLOAD_BYTES + samplesByteLength;
}

function flushPending(state) {
	const samples = state.pendingSamples;
	const chunk = {
		segment: state.pendingSegment,
		chunk_index: state.nextChunkIndex,
		started_at_ms: state.pendingStartedAtMs,
		ended_at_ms: samples[samples.length - 1].tMs,
		sample_count: samples.length,
		payload: payloadFor(samples, state.pendingReps),
	};

	return {
		chunk,
		state: {
			...state,
			nextChunkIndex: state.nextChunkIndex + 1,
			pendingSegment: null,
			pendingStartedAtMs: null,
			pendingSamples: [],
			pendingSamplesByteLength: 0,
			pendingReps: [],
		},
	};
}
