import assert from "node:assert/strict";
import test from "node:test";
import { startPoseTraceSync } from "./pose_trace_sync.mjs";

function harness({ fetch, failOpenOnce = false } = {}) {
	let queued = true;
	let activeWorkout = false;
	let opens = 0;
	let requests = 0;
	let csrfToken = "first-token";
	const timers = new Map();
	let timerId = 0;
	const events = new EventTarget();
	const documentRoot = new EventTarget();
	documentRoot.visibilityState = "visible";
	const status = { hidden: true, dataset: {} };
	const message = { textContent: "" };
	const retry = new EventTarget();
	retry.hidden = true;
	const nodes = {
		"#pose-upload-status": status,
		"#pose-upload-message": message,
		"#pose-upload-retry": retry,
	};
	documentRoot.querySelector = (selector) => selector === "#burpee-session"
		? (activeWorkout ? {} : null)
		: (nodes[selector] || null);
	const store = {
		listReadyTraceUploads: async () => queued ? [{ session_id: 56, client_session_id: "client-56" }] : [],
		readTraceChunkBatch: async (_sessionId, takeChunk) => {
			takeChunk({ chunk_index: 0, payload: { version: 1, samples: [{ tMs: 0 }] } });
			return { hasMore: false };
		},
		settleAcknowledgedFinalUpload: async () => { queued = false; },
	};
	const sync = startPoseTraceSync({
		documentRoot,
		windowRoot: events,
		openStore: async () => {
			opens += 1;
			if (failOpenOnce && opens === 1) throw new Error("storage temporarily blocked");
			return store;
		},
		fetch: async (url, options) => {
			requests += 1;
			return fetch ? fetch(url, options, requests) : { ok: true, json: async () => ({ accepted_indexes: [0], complete: true }) };
		},
		csrfToken: () => csrfToken,
		setTimeout: (callback, delay) => {
			const id = ++timerId;
			timers.set(id, { callback, delay });
			return id;
		},
		clearTimeout: (id) => timers.delete(id),
	});
	return {
		sync, status, message, retry, events, documentRoot, timers,
		get queued() { return queued; },
		get requests() { return requests; },
		get opens() { return opens; },
		setActiveWorkout: (value) => { activeWorkout = value; },
		setCsrfToken: (value) => { csrfToken = value; },
		clickRetry() {
			const event = new Event("click");
			Object.defineProperty(event, "target", { value: { closest: (selector) => selector === "#pose-upload-retry" ? retry : null } });
			documentRoot.dispatchEvent(event);
		},
		async runRetryTimer() {
			const [id, timer] = timers.entries().next().value;
			timers.delete(id);
			return timer.callback();
		},
	};
}

test("a failed upload is visible and automatically retries without another page or online event", async () => {
	const subject = harness({ fetch: async (_url, _options, attempt) => {
		if (attempt === 1) throw new TypeError("connection lost");
		return { ok: true, json: async () => ({ accepted_indexes: [0], complete: true }) };
	} });
	try {
		await subject.sync.retry();
		assert.equal(subject.queued, true);
		assert.equal(subject.status.hidden, false);
		assert.equal(subject.status.dataset.state, "pending");
		assert.match(subject.message.textContent, /poses.*device.*retry/i);
		assert.equal(subject.retry.hidden, false);
		assert.equal(subject.timers.size, 1);

		await subject.runRetryTimer();
		assert.equal(subject.requests, 2);
		assert.equal(subject.queued, false);
		assert.equal(subject.status.hidden, true);
		assert.equal(subject.timers.size, 0);
	} finally { subject.sync.stop(); }
});

test("HTTP rejection is shown with its status, not treated as a successful upload", async () => {
	const subject = harness({ fetch: async () => ({ ok: false, status: 422 }) });
	try {
		await subject.sync.retry();
		assert.equal(subject.queued, true);
		assert.equal(subject.status.hidden, false);
		assert.match(subject.message.textContent, /422/);
		assert.match(subject.message.textContent, /device/i);
	} finally { subject.sync.stop(); }
});

test("temporarily unavailable storage is reopened on the next retry", async () => {
	const subject = harness({ failOpenOnce: true });
	try {
		await subject.sync.retry();
		assert.equal(subject.status.hidden, false);
		assert.match(subject.message.textContent, /storage/i);
		assert.equal(subject.timers.size, 1);
		await subject.runRetryTimer();
		assert.equal(subject.opens, 2);
		assert.equal(subject.queued, false);
	} finally { subject.sync.stop(); }
});

test("automatic retries pause during a workout and resume after navigation", async () => {
	const subject = harness({ fetch: async (_url, _options, attempt) => {
		if (attempt === 1) throw new TypeError("offline");
		return { ok: true, json: async () => ({ accepted_indexes: [0], complete: true }) };
	} });
	try {
		await subject.sync.retry();
		subject.setActiveWorkout(true);
		await subject.runRetryTimer();
		assert.equal(subject.requests, 1);
		assert.equal(subject.queued, true);
		assert.equal(subject.status.hidden, true);

		subject.setActiveWorkout(false);
		subject.events.dispatchEvent(new Event("phx:page-loading-stop"));
		await subject.sync.retry();
		assert.equal(subject.requests, 2);
		assert.equal(subject.queued, false);
	} finally { subject.sync.stop(); }
});

test("retry uses the current CSRF token and stops after disposal", async () => {
	const tokens = [];
	const subject = harness({ fetch: async (_url, options) => {
		tokens.push(options.headers["x-csrf-token"]);
		return { ok: false, status: 503 };
	} });
	await subject.sync.retry();
	subject.setCsrfToken("renewed-token");
	await subject.runRetryTimer();
	assert.deepEqual(tokens, ["first-token", "renewed-token"]);
	assert.equal(subject.timers.size, 1);
	subject.sync.stop();
	assert.equal(subject.timers.size, 0);
	subject.events.dispatchEvent(new Event("online"));
	await subject.sync.retry();
	assert.equal(subject.requests, 2);
});

test("the visible retry button starts another attempt", async () => {
	const subject = harness({ fetch: async (_url, _options, attempt) => {
		if (attempt === 1) return { ok: false, status: 503 };
		return { ok: true, json: async () => ({ accepted_indexes: [0], complete: true }) };
	} });
	try {
		await subject.sync.retry();
		// The document-level listener survives LiveView replacing the layout nodes.
		subject.clickRetry();
		await new Promise((resolve) => setImmediate(resolve));
		assert.equal(subject.requests, 2);
		assert.equal(subject.queued, false);
	} finally { subject.sync.stop(); }
});
