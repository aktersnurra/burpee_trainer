import assert from "node:assert/strict";
import test from "node:test";

import {
	canDrainPoseTraces,
	createPoseTraceUploader,
	MAX_TRACE_REQUEST_BYTES,
} from "./pose_trace_uploader.mjs";

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
		async listTraceChunks(sessionId) {
			assert.equal(sessionId, 99);
			return chunks.map((item) => structuredClone(item));
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
