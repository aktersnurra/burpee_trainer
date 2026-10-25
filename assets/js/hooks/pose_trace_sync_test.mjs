import assert from "node:assert/strict";
import test from "node:test";
import { startPoseTraceSync } from "./pose_trace_sync.mjs";

function queuedChunk(sessionId) {
	return {
		session_id: sessionId, client_session_id: `client-${sessionId}`,
		chunk_index: 0, segment: "main", started_at_ms: 0, ended_at_ms: 1,
		sample_count: 1, payload: { version: 1, samples: [{ tMs: 0 }] },
	};
}

function harness({ fetch, failOpenOnce = false, emptySessionIds = [], frameSessionIds = [56] } = {}) {
	const queues = new Map([
		...emptySessionIds.map((id) => [id, []]),
		...frameSessionIds.map((id) => [id, [queuedChunk(id)]]),
	]);
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
	const dismiss = { hidden: true };
	const nodes = {
		"#pose-upload-status": status,
		"#pose-upload-message": message,
		"#pose-upload-retry": retry,
		"#pose-upload-dismiss": dismiss,
	};
	documentRoot.querySelector = (selector) => selector === "#burpee-session"
		? (activeWorkout ? {} : null)
		: (nodes[selector] || null);
	const store = {
		listReadyTraceUploads: async () => [...queues.keys()].sort((a, b) => a - b)
			.map((id) => ({ session_id: id, client_session_id: `client-${id}` })),
		readTraceChunkBatch: async (sessionId, takeChunk) => {
			for (const chunk of queues.get(sessionId)) if (!takeChunk(chunk)) return { hasMore: true };
			return { hasMore: false };
		},
		settleAcknowledgedFinalUpload: async (sessionId) => { queues.delete(sessionId); },
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
		CompressionStream: null,
		setTimeout: (callback, delay) => {
			const id = ++timerId;
			timers.set(id, { callback, delay });
			return id;
		},
		clearTimeout: (id) => timers.delete(id),
	});
	return {
		sync, status, message, retry, dismiss, events, documentRoot, timers,
		get queued() { return queues.has(56); },
		get queuedSessionIds() { return [...queues.keys()].sort((a, b) => a - b); },
		enqueueFrames: (sessionId) => queues.set(sessionId, [queuedChunk(sessionId)]),
		get requests() { return requests; },
		get opens() { return opens; },
		setActiveWorkout: (value) => { activeWorkout = value; },
		setCsrfToken: (value) => { csrfToken = value; },
		click(selector) {
			const event = new Event("click");
			Object.defineProperty(event, "target", { value: { closest: (match) => match === selector ? nodes[selector] : null } });
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
	const subject = harness({ fetch: async () => ({ ok: false, status: 503 }) });
	try {
		await subject.sync.retry();
		assert.equal(subject.queued, true);
		assert.equal(subject.status.hidden, false);
		assert.match(subject.message.textContent, /503/);
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

test("an empty queue shows a dismissible notice without futile retry timers", async () => {
	const subject = harness({ emptySessionIds: [54], frameSessionIds: [] });
	try {
		await subject.sync.retry();
		assert.equal(subject.status.dataset.state, "blocked");
		assert.equal(subject.status.hidden, false);
		assert.match(subject.message.textContent, /54/);
		assert.equal(subject.retry.hidden, true);
		assert.equal(subject.dismiss.hidden, false);
		assert.equal(subject.timers.size, 0);
		assert.equal(subject.requests, 0);
		assert.deepEqual(subject.queuedSessionIds, [54]);
	} finally { subject.sync.stop(); }
});

test("dismissing an empty queue notice retains its record and stays quiet across navigation", async () => {
	const subject = harness({ emptySessionIds: [54], frameSessionIds: [] });
	try {
		await subject.sync.retry();
		subject.click("#pose-upload-dismiss");
		assert.equal(subject.status.hidden, true);
		subject.events.dispatchEvent(new Event("phx:page-loading-stop"));
		await subject.sync.retry();
		assert.equal(subject.status.hidden, true);
		assert.equal(subject.timers.size, 0);
		assert.equal(subject.requests, 0);
		assert.deepEqual(subject.queuedSessionIds, [54]);
	} finally { subject.sync.stop(); }
});

test("an older empty queue does not hide or stop another workout's retry", async () => {
	const subject = harness({ emptySessionIds: [54], fetch: async (_url, _options, attempt) => {
		if (attempt === 1) return { ok: false, status: 503 };
		return { ok: true, json: async () => ({ accepted_indexes: [0], complete: true }) };
	} });
	try {
		await subject.sync.retry();
		assert.equal(subject.status.dataset.state, "pending");
		assert.match(subject.message.textContent, /503/);
		assert.equal(subject.retry.hidden, false);
		assert.equal(subject.timers.size, 1);
		await subject.runRetryTimer();
		assert.equal(subject.requests, 2);
		assert.deepEqual(subject.queuedSessionIds, [54]);
		assert.equal(subject.status.dataset.state, "blocked");
		assert.equal(subject.timers.size, 0);
	} finally { subject.sync.stop(); }
});

test("dismissing a blocked notice does not suppress a later workout's upload error", async () => {
	const subject = harness({ emptySessionIds: [54], frameSessionIds: [], fetch: async () => ({ ok: false, status: 503 }) });
	try {
		await subject.sync.retry();
		subject.click("#pose-upload-dismiss");
		subject.enqueueFrames(56);
		subject.events.dispatchEvent(new Event("burpee:trace-upload-ready"));
		await subject.sync.retry();
		assert.equal(subject.status.hidden, false);
		assert.equal(subject.status.dataset.state, "pending");
		assert.match(subject.message.textContent, /503/);
		assert.equal(subject.timers.size, 1);
		assert.deepEqual(subject.queuedSessionIds, [54, 56]);
	} finally { subject.sync.stop(); }
});

test("the visible retry button starts another attempt", async () => {
	const subject = harness({ fetch: async (_url, _options, attempt) => {
		if (attempt === 1) return { ok: false, status: 503 };
		return { ok: true, json: async () => ({ accepted_indexes: [0], complete: true }) };
	} });
	try {
		await subject.sync.retry();
		// The document-level listener survives LiveView replacing the layout nodes.
		subject.click("#pose-upload-retry");
		await new Promise((resolve) => setImmediate(resolve));
		assert.equal(subject.requests, 2);
		assert.equal(subject.queued, false);
	} finally { subject.sync.stop(); }
});

test("a ready notification during a drain rescans before going idle", async () => {
  let release;
  let entered;
  const started = new Promise(resolve => { entered = resolve; });
  const pending = new Promise(resolve => { release = resolve; });
  const ids = [];
  const subject = harness({ fetch: async (_url, options) => {
    const body = JSON.parse(options.body);
    ids.push(body.session_id);
    if (body.session_id === 56) { entered(); await pending; }
    return { ok: true, json: async () => ({ accepted_indexes: [0], complete: true }) };
  } });
  try {
    await started;
    subject.enqueueFrames(57);
    subject.events.dispatchEvent(new Event("burpee:trace-upload-ready"));
    const draining = subject.sync.retry();
    release();
    await draining;
    assert.deepEqual(ids, [56, 57]);
    assert.deepEqual(subject.queuedSessionIds, []);
  } finally { subject.sync.stop(); }
});

test("permanent rejection is dismissible, retained, and does not schedule retries", async () => {
  for (const status of [400, 401, 403, 404, 413, 422]) {
    const subject = harness({ fetch: async () => ({ ok: false, status }) });
    try {
      await subject.sync.retry();
      assert.equal(subject.status.dataset.state, "blocked");
      assert.equal(subject.timers.size, 0);
      assert.equal(subject.dismiss.hidden, false);
      assert.match(subject.message.textContent, new RegExp(String(status)));
      assert.equal(subject.queued, true);
      subject.click("#pose-upload-dismiss");
      assert.equal(subject.status.hidden, true);
      subject.events.dispatchEvent(new Event("phx:page-loading-stop"));
      await subject.sync.retry();
      // Sign-in errors are retried on the next event; every other rejection stays blocked.
      assert.equal(subject.requests, [401, 403].includes(status) ? 2 : 1);
    } finally { subject.sync.stop(); }
  }
});
