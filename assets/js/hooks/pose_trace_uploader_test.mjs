import assert from "node:assert/strict";
import test from "node:test";

import {
	canDrainPoseTraces,
	createPoseTraceUploader as productionUploader,
	MAX_TRACE_REQUEST_BYTES,
} from "./pose_trace_uploader.mjs";

function createPoseTraceUploader(options) {
	return productionUploader({ CompressionStream: null, ...options });
}

function chunk(index) {
	return {
		session_id: 99,
		client_session_id: "client-1",
		chunk_index: index,
		segment: "main",
		started_at_ms: index * 1_000,
		ended_at_ms: (index + 1) * 1_000,
		sample_count: 1,
		payload: { version: 1, samples: [{ tMs: index * 1_000 }] },
	};
}

function uploadStore(
	initialChunks,
	{ ready = true, rejectFinalSettlementOnce = false } = {},
) {
	let chunks = initialChunks.map((item) => structuredClone(item));
	let marker = ready;
	return {
		async listReadyTraceUploads() {
			return marker ? [{ client_session_id: "client-1", session_id: 99 }] : [];
		},
		async readTraceChunkBatch(sessionId, takeChunk) {
			assert.equal(sessionId, 99);
			for (const item of chunks) {
				if (!takeChunk(structuredClone(item))) return { hasMore: true };
			}
			return { hasMore: false };
		},
		async deleteTraceChunks(sessionId, indexes) {
			assert.equal(sessionId, 99);
			chunks = chunks.filter((item) => !indexes.includes(item.chunk_index));
		},
		async settleAcknowledgedFinalUpload(sessionId, indexes) {
			assert.equal(sessionId, 99);
			if (rejectFinalSettlementOnce) {
				rejectFinalSettlementOnce = false;
				throw new Error("forced final settlement abort");
			}
			chunks = chunks.filter((item) => !indexes.includes(item.chunk_index));
			marker = false;
		},
		remainingIndexes() {
			return chunks.map((item) => item.chunk_index);
		},
		uploadMarkerExists() {
			return marker;
		},
	};
}

function jsonResponse(body, { ok = true } = {}) {
	return {
		ok,
		async json() {
			return body;
		},
	};
}

function parseJson(body) {
	try {
		return JSON.parse(body);
	} catch (error) {
		assert.fail(`request body must be valid JSON: ${error.message}`);
	}
}

test("deferred uploads stay idle while a workout session owns the page", () => {
	const activeSessionDocument = {
		querySelector: (selector) =>
			selector === "#burpee-session" ? { id: "burpee-session" } : null,
	};
	const nonSessionDocument = { querySelector: () => null };

	assert.equal(canDrainPoseTraces(activeSessionDocument), false);
	assert.equal(canDrainPoseTraces(nonSessionDocument), true);
});

test("uploader acknowledges only accepted chunks", async () => {
	const store = uploadStore([chunk(0), chunk(1)]);
	const uploader = createPoseTraceUploader({
		store,
		fetch: async () => jsonResponse({ accepted_indexes: [0], complete: false }),
		csrfToken: "token",
		batchSize: 2,
	});

	await uploader.drain();

	assert.deepEqual(store.remainingIndexes(), [1]);
	assert.equal(store.uploadMarkerExists(), true);
});

test("network failure keeps chunks queued and resolves without throwing", async () => {
	const store = uploadStore([chunk(0)]);
	const uploader = createPoseTraceUploader({
		store,
		fetch: async () => {
			throw new TypeError("offline");
		},
		csrfToken: "token",
	});

	await uploader.drain();

	assert.deepEqual(store.remainingIndexes(), [0]);
	assert.equal(store.uploadMarkerExists(), true);
});

test("an empty ready marker is retained without a durable final acknowledgement", async () => {
	const store = uploadStore([]);
	let requests = 0;
	const uploader = createPoseTraceUploader({
		store,
		fetch: async () => {
			requests += 1;
			return jsonResponse({ accepted_indexes: [], complete: true });
		},
		csrfToken: "token",
	});

	await uploader.drain();

	assert.equal(requests, 0);
	assert.equal(store.uploadMarkerExists(), true);
});

test("accepted final chunks survive incomplete acknowledgement, retry failure, and eventually clear on complete true", async () => {
	const store = uploadStore([chunk(0)]);
	const requestBodies = [];
	const outcomes = [
		jsonResponse({ accepted_indexes: [0], complete: false }),
		new TypeError("offline during final acknowledgement retry"),
		jsonResponse({ accepted_indexes: [0], complete: true }),
	];
	const uploader = createPoseTraceUploader({
		store,
		fetch: async (_path, options) => {
			requestBodies.push(parseJson(options.body));
			const outcome = outcomes.shift();
			if (outcome instanceof Error) throw outcome;
			return outcome;
		},
		csrfToken: "token",
	});

	await uploader.drain();
	assert.deepEqual(store.remainingIndexes(), [0]);
	assert.equal(store.uploadMarkerExists(), true);

	await uploader.drain();
	assert.deepEqual(store.remainingIndexes(), [0]);
	assert.equal(store.uploadMarkerExists(), true);

	await uploader.drain();
	assert.deepEqual(
		requestBodies.map((body) => body.chunks.map((item) => item.chunk_index)),
		[[0], [0], [0]],
	);
	assert.deepEqual(
		requestBodies.map((body) => body.complete),
		[true, true, true],
	);
	assert.deepEqual(store.remainingIndexes(), []);
	assert.equal(store.uploadMarkerExists(), false);
});

test("final acknowledgement settlement abort retains chunks and marker for retry", async () => {
	const store = uploadStore([chunk(0), chunk(1)], {
		rejectFinalSettlementOnce: true,
	});
	let requests = 0;
	const uploader = createPoseTraceUploader({
		store,
		fetch: async () => {
			requests += 1;
			return jsonResponse({ accepted_indexes: [0, 1], complete: true });
		},
		csrfToken: "token",
	});

	await uploader.drain();
	assert.deepEqual(store.remainingIndexes(), [0, 1]);
	assert.equal(store.uploadMarkerExists(), true);

	await uploader.drain();
	assert.equal(requests, 2);
	assert.deepEqual(store.remainingIndexes(), []);
	assert.equal(store.uploadMarkerExists(), false);
});

test("uploader sends bounded batches and completes only the final batch", async () => {
	const store = uploadStore([chunk(0), chunk(1), chunk(2)]);
	const requests = [];
	const uploader = createPoseTraceUploader({
		store,
		fetch: async (path, options) => {
			const body = parseJson(options.body);
			requests.push({ path, options, body });
			return jsonResponse({
				accepted_indexes: body.chunks.map((item) => item.chunk_index),
				complete: body.complete,
			});
		},
		csrfToken: "csrf-token",
		batchSize: 2,
	});

	await uploader.drain();

	assert.equal(requests.length, 2);
	assert.deepEqual(
		requests.map((request) => request.body.complete),
		[false, true],
	);
	assert.deepEqual(
		requests.map((request) =>
			request.body.chunks.map((item) => item.chunk_index),
		),
		[[0, 1], [2]],
	);
	assert.equal(requests[0].path, "/api/session-pose-traces");
	assert.equal(requests[0].options.headers["x-csrf-token"], "csrf-token");
	assert.equal(requests[0].options.headers["content-type"], "application/json");
	assert.equal(requests[0].body.session_id, 99);
	assert.equal(requests[0].body.client_session_id, "client-1");
	assert.equal(Object.hasOwn(requests[0].body.chunks[0], "session_id"), false);
	assert.equal(
		Object.hasOwn(requests[0].body.chunks[0], "client_session_id"),
		false,
	);
	assert.deepEqual(store.remainingIndexes(), []);
	assert.equal(store.uploadMarkerExists(), false);
});

test("uploader splits ready chunks by serialized request bytes", async () => {
	const largeChunks = [chunk(0), chunk(1)].map((item) => ({
		...item,
		payload: { version: 1, samples: ["x".repeat(300_000)] },
	}));
	const store = uploadStore(largeChunks);
	const requests = [];
	const uploader = createPoseTraceUploader({
		store,
		fetch: async (_path, options) => {
			const body = parseJson(options.body);
			requests.push({ raw: options.body, body });
			return jsonResponse({
				accepted_indexes: body.chunks.map((item) => item.chunk_index),
				complete: body.complete,
			});
		},
		csrfToken: "token",
	});

	await uploader.drain();

	assert.equal(requests.length, 2);
	assert.ok(
		requests.every(
			({ raw }) =>
				new TextEncoder().encode(raw).byteLength <= MAX_TRACE_REQUEST_BYTES,
		),
	);
	assert.deepEqual(store.remainingIndexes(), []);
	assert.equal(store.uploadMarkerExists(), false);
});

test("uploading reads a bounded cursor batch with at most one extra chunk", async () => {
	const chunks = new Map(Array.from({ length: 50 }, (_, index) => [index, {
		...chunk(index), payload: { version: 1, samples: [{ padding: "x".repeat(190_000) }] },
	}]));
	let marker = true;
	const pageReads = [];
	const batches = [];
	const store = {
		listReadyTraceUploads: async () => marker ? [{ session_id: 99, client_session_id: "client-1" }] : [],
		listTraceChunks: () => assert.fail("whole-trace read is forbidden"),
		async readTraceChunkBatch(_sessionId, takeChunk) {
			let reads = 0;
			for (const value of chunks.values()) {
				reads += 1;
				if (!takeChunk(value)) { pageReads.push(reads); return { hasMore: true }; }
			}
			pageReads.push(reads);
			return { hasMore: false };
		},
		async deleteTraceChunks(_sessionId, indexes) { for (const index of indexes) chunks.delete(index); },
		async settleAcknowledgedFinalUpload(_sessionId, indexes) {
			for (const index of indexes) chunks.delete(index);
			marker = false;
		},
	};
	const uploader = createPoseTraceUploader({
		store,
		csrfToken: "token",
		fetch: async (_url, { body }) => {
			assert.ok(new TextEncoder().encode(body).byteLength <= MAX_TRACE_REQUEST_BYTES);
			const request = JSON.parse(body);
			batches.push(request.chunks.map((value) => value.chunk_index));
			return jsonResponse({ accepted_indexes: batches.at(-1), complete: request.complete });
		},
	});
	assert.equal((await uploader.drain()).status, "complete");
	assert.deepEqual(batches[0], [0, 1]);
	assert.ok(pageReads.every((reads) => reads <= 3));
	assert.equal(chunks.size, 0);
	assert.equal(marker, false);
});

test("an empty queue is blocked rather than retryable and retains its upload record", async () => {
	const store = uploadStore([]);
	const uploader = createPoseTraceUploader({ store, csrfToken: "token", fetch: () => assert.fail("no frames must not create an empty completed server run") });
	const result = await uploader.drain();
	assert.equal(result.status, "blocked");
	assert.deepEqual(result.uploads, [{ sessionId: 99, status: "blocked", reason: "missing_chunks" }]);
	assert.equal(store.uploadMarkerExists(), true);
});

test("failed HTTP responses report the status and retain every queued frame", async () => {
	for (const status of [401, 403, 422, 429, 500, 503]) {
		const store = uploadStore([chunk(0)]);
		const uploader = createPoseTraceUploader({
			store,
			fetch: async () => ({ ok: false, status }),
			csrfToken: "token",
		});

		const result = await uploader.drain();
		const expected = [401, 403, 422].includes(status) ? "blocked" : "pending";
		assert.equal(result.status, expected);
		assert.deepEqual(result.uploads, [{ sessionId: 99, status: expected, reason: "http", httpStatus: status }]);
		assert.deepEqual(store.remainingIndexes(), [0]);
		assert.equal(store.uploadMarkerExists(), true);
	}
});

test("an upload refused for sign-in is retried on the next drain without a reload", async () => {
	const store = uploadStore([chunk(0)]);
	let status = 401;
	const uploader = createPoseTraceUploader({
		store,
		fetch: async () => (status === 200 ? { ok: true, status, json: async () => ({ accepted_indexes: [0], complete: true }) } : { ok: false, status }),
		csrfToken: "token",
	});

	assert.equal((await uploader.drain()).status, "blocked");
	status = 200;
	assert.equal((await uploader.drain()).status, "complete");
	assert.equal(store.uploadMarkerExists(), false);
});

test("a timed-out request reports failure without losing its frames", async (t) => {
	t.mock.timers.enable({ apis: ["setTimeout"] });
	const store = uploadStore([chunk(0)]);
	const uploader = createPoseTraceUploader({
		store,
		fetch: (_url, { signal }) => new Promise((_resolve, reject) => {
			signal.addEventListener("abort", () => reject(signal.reason), { once: true });
		}),
		csrfToken: "token",
		requestTimeoutMs: 30_000,
	});

	const pending = uploader.drain();
	await new Promise((resolve) => setImmediate(resolve));
	t.mock.timers.tick(30_000);
	const result = await pending;
	assert.equal(result.status, "pending");
	assert.equal(result.uploads[0].reason, "timeout");
	assert.deepEqual(store.remainingIndexes(), [0]);
	assert.equal(store.uploadMarkerExists(), true);
});

test("one failed upload does not prevent another workout's frames from uploading", async () => {
	const first = uploadStore([chunk(0)]);
	const second = uploadStore([chunk(0)]);
	const store = {
		listReadyTraceUploads: async () => [
			{ session_id: 99, client_session_id: "client-1" },
			{ session_id: 100, client_session_id: "client-2" },
		],
		readTraceChunkBatch: (id, takeChunk) => (id === 99 ? first : second).readTraceChunkBatch(99, takeChunk),
		deleteTraceChunks: (id, indexes) => (id === 99 ? first : second).deleteTraceChunks(99, indexes),
		settleAcknowledgedFinalUpload: (id, indexes) => (id === 99 ? first : second).settleAcknowledgedFinalUpload(99, indexes),
	};
	const uploader = createPoseTraceUploader({
		store,
		fetch: async (_url, { body }) => {
			if (JSON.parse(body).session_id === 99) throw new TypeError("offline");
			return jsonResponse({ accepted_indexes: [0], complete: true });
		},
		csrfToken: "token",
	});

	const result = await uploader.drain();
	assert.equal(result.status, "pending");
	assert.equal(result.uploads[0].reason, "network");
	assert.equal(result.uploads[1].status, "uploaded");
	assert.equal(first.uploadMarkerExists(), true);
	assert.equal(second.uploadMarkerExists(), false);
});

test("concurrent drains share one in-flight request", async () => {
	const store = uploadStore([chunk(0)]);
	let resolveRequest;
	let requests = 0;
	const uploader = createPoseTraceUploader({
		store,
		fetch: async () => {
			requests += 1;
			return new Promise((resolve) => {
				resolveRequest = resolve;
			});
		},
		csrfToken: "token",
	});

	const first = uploader.drain();
	const second = uploader.drain();
	await new Promise((resolve) => setImmediate(resolve));
	assert.equal(requests, 1);
	resolveRequest(jsonResponse({ accepted_indexes: [0], complete: true }));
	await Promise.all([first, second]);
	assert.equal(store.uploadMarkerExists(), false);
});

test("final upload declares the expected total, including previously acknowledged indexes", async () => {
  const store = uploadStore([chunk(7)]);
  let sent;
  const uploader = createPoseTraceUploader({ store, csrfToken: "token", fetch: async (_url, {body}) => {
    sent = JSON.parse(body);
    return jsonResponse({ accepted_indexes: [7], complete: true });
  } });
  await uploader.drain();
  assert.equal(sent.expected_chunk_count, 8);
});

test("gzip-capable browsers send compressed JSON with the final manifest", async () => {
  const store = uploadStore([chunk(0)]);
  let received;
  const uploader = productionUploader({ store, csrfToken: "token", fetch: async (_url, options) => {
    assert.equal(options.headers["content-encoding"], "gzip");
    const decompressed = new Blob([options.body]).stream().pipeThrough(new DecompressionStream("gzip"));
    received = await new Response(decompressed).json();
    return jsonResponse({ accepted_indexes: [0], complete: true });
  } });
  assert.equal((await uploader.drain()).status, "complete");
  assert.equal(received.expected_chunk_count, 1);
  assert.equal(received.chunks[0].payload.samples[0].tMs, 0);
  assert.deepEqual(store.remainingIndexes(), []);
});
