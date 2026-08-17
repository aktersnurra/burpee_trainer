import assert from "node:assert/strict";
import test from "node:test";

import {
	MAX_TRACE_REQUEST_BYTES,
	canDrainPoseTraces,
	createPoseTraceUploader,
} from "./pose_trace_uploader.mjs";

function chunk(index) {
	return {
		client_session_id: "client-1",
		chunk_index: index,
		segment: "main",
		started_at_ms: index * 1_000,
		ended_at_ms: (index + 1) * 1_000,
		sample_count: 1,
		payload: { version: 1, samples: [{ tMs: index * 1_000 }] },
	};
}

function largeChunk(index, bytes = 170_000) {
	return {
		...chunk(index),
		payload: {
			version: 1,
			samples: [{ tMs: index * 1_000, landmark_data: "x".repeat(bytes) }],
		},
	};
}

function nearBudgetChunks() {
	return [largeChunk(0), largeChunk(1), largeChunk(2), largeChunk(3)];
}

function uploadStore(initialChunks, { ready = true } = {}) {
	let chunks = initialChunks.map((item) => structuredClone(item));
	let marker = ready;
	return {
		async listReadyTraceUploads() {
			return marker ? [{ client_session_id: "client-1", session_id: 99 }] : [];
		},
		async listTraceChunks(clientSessionId) {
			assert.equal(clientSessionId, "client-1");
			return chunks.map((item) => structuredClone(item));
		},
		async deleteTraceChunks(clientSessionId, indexes) {
			assert.equal(clientSessionId, "client-1");
			chunks = chunks.filter((item) => !indexes.includes(item.chunk_index));
		},
		async completeTraceUpload(clientSessionId) {
			assert.equal(clientSessionId, "client-1");
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

test("empty ready upload markers are removed without a request", async () => {
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
	assert.equal(
		Object.hasOwn(requests[0].body.chunks[0], "client_session_id"),
		false,
	);
	assert.deepEqual(store.remainingIndexes(), []);
	assert.equal(store.uploadMarkerExists(), false);
});

test("uploader splits a ready queue by serialized request bytes", async () => {
	const store = uploadStore(nearBudgetChunks());
	const requests = [];
	const uploader = createPoseTraceUploader({
		store,
		fetch: async (_path, options) => {
			const body = parseJson(options.body);
			requests.push({ raw: options.body, body });
			return jsonResponse({
				accepted_indexes: body.chunks.map(({ chunk_index }) => chunk_index),
				complete: body.complete,
			});
		},
		csrfToken: "token",
	});

	await uploader.drain();

	assert.ok(requests.length > 1);
	assert.ok(requests.every(({ body }) => body.chunks.length > 0));
	assert.ok(
		requests.every(
			({ raw }) =>
				new TextEncoder().encode(raw).byteLength <= MAX_TRACE_REQUEST_BYTES,
		),
	);
	assert.deepEqual(store.remainingIndexes(), []);
	assert.equal(store.uploadMarkerExists(), false);
});

test("413 retains the queued chunks and ready marker", async () => {
	const store = uploadStore([largeChunk(0, 400_000)]);
	let requests = 0;
	const uploader = createPoseTraceUploader({
		store,
		fetch: async () => {
			requests += 1;
			return { ok: false, status: 413 };
		},
		csrfToken: "token",
	});

	await uploader.drain();

	assert.equal(requests, 1);
	assert.deepEqual(store.remainingIndexes(), [0]);
	assert.equal(store.uploadMarkerExists(), true);
});

test("409 conflict retains every queued chunk and ready marker", async () => {
	const store = uploadStore([chunk(0), chunk(1)]);
	const uploader = createPoseTraceUploader({
		store,
		fetch: async () => ({ ok: false, status: 409 }),
		csrfToken: "token",
	});

	await uploader.drain();

	assert.deepEqual(store.remainingIndexes(), [0, 1]);
	assert.equal(store.uploadMarkerExists(), true);
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
