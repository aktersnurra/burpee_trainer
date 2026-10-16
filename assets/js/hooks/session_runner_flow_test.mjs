import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import SessionHook from "./session_hook.js";
import { initialFlowState } from "./session_flow_fsm.mjs";
import { initialSegmentState } from "./session_segment_fsm.mjs";
import { openSessionStore } from "./session_store.mjs";

const compiledProgram = JSON.parse(
	readFileSync(new URL("fixtures/compiled_program.json", import.meta.url), "utf8"),
);

class FakeClock {
	constructor() {
		this.now = 0;
		this.nextId = 1;
		this.frames = new Map();
		this.timeouts = new Map();
	}

	requestFrame = (callback) => {
		const id = this.nextId++;
		this.frames.set(id, callback);
		return id;
	};

	cancelFrame = (id) => this.frames.delete(id);

	setTimeout = (callback, delay) => {
		const id = this.nextId++;
		this.timeouts.set(id, { callback, due: this.now + delay });
		return id;
	};

	clearTimeout = (id) => this.timeouts.delete(id);

	advanceCountdownTo(target) {
		while (true) {
			const next = [...this.timeouts.entries()]
				.filter(([, timer]) => timer.due <= target)
				.sort(([, left], [, right]) => left.due - right.due)[0];
			if (!next) break;
			const [id, timer] = next;
			this.timeouts.delete(id);
			this.now = timer.due;
			timer.callback();
		}
		this.now = target;
	}

	runRunnerFrameAt(milliseconds) {
		this.now = milliseconds;
		const next = this.frames.entries().next().value;
		assert.ok(next, "runner should schedule an animation frame");
		const [id, callback] = next;
		this.frames.delete(id);
		callback();
	}
}

function statefulIndexedDbHarness() {
	const names = ["completion_drafts", "pose_trace_chunks", "trace_uploads"];
	const committed = new Map(names.map((name) => [name, new Map()]));
	const normalize = (key) => (Array.isArray(key) ? JSON.stringify(key) : key);
	const keyFor = (name, value) => {
		if (name === "completion_drafts") return [value.session_id, value.content_hash];
		if (name === "pose_trace_chunks") return [value.session_id, value.chunk_index];
		return value.session_id;
	};
	const clone = (values) =>
		new Map([...values].map(([key, value]) => [key, structuredClone(value)]));

	const database = {
		objectStoreNames: { contains: (name) => committed.has(name) },
		createObjectStore() {
			throw new Error("version 2 schema already exists");
		},
		deleteObjectStore() {
			throw new Error("version 2 schema must not be replaced");
		},
		transaction(requestedNames, mode) {
			assert.ok(["readonly", "readwrite"].includes(mode));
			const transactionNames = Array.isArray(requestedNames)
				? requestedNames
				: [requestedNames];
			const working = new Map(
				transactionNames.map((name) => [name, clone(committed.get(name))]),
			);
			let pending = 0;
			let settled = false;
			let completionQueued = false;
			const transaction = {
				error: null,
				objectStore(name) {
					assert.equal(transactionNames.includes(name), true);
					const values = working.get(name);
					return {
						getAll: () =>
							request(() => [...values.values()].map((value) => structuredClone(value))),
						put: (value) =>
							request(() => {
								values.set(normalize(keyFor(name, value)), structuredClone(value));
							}),
						delete: (key) => request(() => values.delete(normalize(key))),
					};
				},
			};
			const request = (operation) => {
				const indexedRequest = { result: undefined, error: null };
				pending += 1;
				queueMicrotask(() => {
					if (settled) return;
					indexedRequest.result = operation();
					indexedRequest.onsuccess?.();
					pending -= 1;
					if (completionQueued) return;
					completionQueued = true;
					queueMicrotask(() => {
						completionQueued = false;
						if (settled || pending !== 0) return;
						settled = true;
						for (const name of transactionNames) committed.set(name, working.get(name));
						transaction.oncomplete?.();
					});
				});
				return indexedRequest;
			};
			return transaction;
		},
	};

	return {
		indexedDB: {
			open() {
				const request = { result: database, error: null };
				queueMicrotask(() => request.onsuccess?.());
				return request;
			},
		},
	};
}

function element(value = "") {
	return {
		value,
		style: {},
		attributes: new Map(),
		setAttribute(name, attributeValue) {
			this.attributes.set(name, attributeValue);
		},
		removeAttribute(name) {
			this.attributes.delete(name);
		},
	};
}

function runnerHarness(store) {
	const controls = new Map([
		["#workout_session_burpee_type", element("six_count")],
		["#session-pause-actions", element()],
		["#finish-early-btn", element()],
	]);
	const renderedModels = [];
	const context = {
		...SessionHook,
		el: { querySelector: (selector) => controls.get(selector) || null },
		flow: initialFlowState(),
		segment: initialSegmentState(),
		activeSegment: null,
		program: compiledProgram,
		timeline: [],
		startTime: null,
		paused: false,
		rafId: null,
		countdownPaused: false,
		countdownCount: null,
		countdownTimeoutId: null,
		countdownRafId: null,
		countdownStartedAt: null,
		countdownElapsedMs: 0,
		renderCountdownFrame: null,
		countdownStepStarted: null,
		countdownStepElapsed: 0,
		doneReps: 0,
		lastDownCueKey: null,
		tracking: {},
		trackerReadiness: "not_ready",
		lifecycleGeneration: 1,
		lifecycleDestroyed: false,
		sessionId: 71,
		contentHash: compiledProgram.program_hash,
		clientSessionId: "client-compiled-flow",
		store,
		storeReady: Promise.resolve(store),
		traceWrite: Promise.resolve(true),
		draftWrite: Promise.resolve(true),
		pendingTraceChunks: new Map(),
		completionDraftPending: false,
		inMemoryCompletionDraft: null,
		serverCompletion: null,
		pendingServerCompletionFacts: null,
		saveCleanup: Promise.resolve(),
		traceRetentionAvailable: true,
		renderer: {
			renderFlowState() {}, renderCompletion() {}, clearSaveErrors() {},
			renderSaveErrors() {}, clearCountdown() {}, updateTotalCounter() {},
			updateTotalGoal() {}, renderTimer() {}, enterWorkPhase() {}, triggerDown() {},
			updateCurrentSetRepCount() {}, updateWorkFill() {}, enterRestPhase() {},
			renderRestProgress() {}, updatePauseButton() {},
			renderDisplayModel(model) { renderedModels.push(model); },
		},
		audio: { ensureRunning() {}, playLeadBeep() {}, playRepBeep() {}, stop() {} },
		wakeLock: { acquire() {}, release() {} },
		pushEvent(name, payload, reply) {
			context.savedPayload = payload;
			reply({ status: "ok", session_id: 71, redirect_to: "/" });
		},
	};
	return { context, renderedModels };
}

test("a compiler-produced program runs through SessionHook countdown, rests, completion payload, and IndexedDB evidence finalization", async () => {
	const clock = new FakeClock();
	const original = {
		performance: globalThis.performance,
		requestAnimationFrame: globalThis.requestAnimationFrame,
		cancelAnimationFrame: globalThis.cancelAnimationFrame,
		setTimeout: globalThis.setTimeout,
		clearTimeout: globalThis.clearTimeout,
		document: globalThis.document,
		window: globalThis.window,
		CustomEvent: globalThis.CustomEvent,
	};
	globalThis.performance = { now: () => clock.now };
	globalThis.requestAnimationFrame = clock.requestFrame;
	globalThis.cancelAnimationFrame = clock.cancelFrame;
	globalThis.setTimeout = clock.setTimeout;
	globalThis.clearTimeout = clock.clearTimeout;
	globalThis.CustomEvent = class { constructor(type, init = {}) { this.type = type; this.detail = init.detail; } };
	globalThis.document = { visibilityState: "visible", dispatchEvent() {} };
	globalThis.window = { dispatchEvent() {}, location: { assign() {} } };

	try {
		const store = await openSessionStore(statefulIndexedDbHarness().indexedDB);
		const { context, renderedModels } = runnerHarness(store);
		context.queueTraceChunk({ chunk_index: 0, payload: { sample: "evidence" } });
		await context.traceWrite;
		await store.saveDraft({
			session_id: 71, content_hash: "other-hash", client_session_id: "other-client",
		});

		context.dispatchFlow({
			type: "SESSION_READY",
			workoutTimeline: compiledProgram.events,
			choices: { camera: false, warmup: false },
		});
		context.dispatchFlow({ type: "START" });
		assert.equal(context.flow.mode, "workout_running");
		assert.equal(context.segment.mode, "countdown");
		clock.advanceCountdownTo(5_000);
		assert.equal(context.segment.mode, "running");
		assert.equal(context.startTime, 5_000);

		const frameAt = (elapsedSec) => {
			clock.runRunnerFrameAt(5_000 + elapsedSec * 1_000);
			return renderedModels.at(-1);
		};
		assert.equal(frameAt(10).visual.state, "rest");
		assert.equal(context.segment.reps.previousFrame.phase_remaining, 5);
		assert.equal(frameAt(15).visual.state, "work_active");
		assert.equal(frameAt(25).visual.state, "rest_count_in");
		assert.equal(context.segment.reps.previousFrame.phase_remaining, 3);
		assert.equal(frameAt(28).visual.state, "work_active");
		frameAt(43);
		assert.equal(context.flow.mode, "completion_review");
		await context.draftWrite;

		context.saveCompletion();
		await context.saveCleanup;
		assert.equal(context.flow.mode, "persisted");
		assert.equal(context.savedPayload.workout_session.duration_sec_planned, 43);
		assert.equal(Number.isInteger(context.savedPayload.workout_session.duration_sec_planned), true);
		assert.equal(await store.loadDraft({ sessionId: 71, contentHash: compiledProgram.program_hash }), null);
		assert.ok(await store.loadDraft({ sessionId: 71, contentHash: "other-hash" }));
		assert.deepEqual(await store.listReadyTraceUploads(), [
			{ session_id: 71, client_session_id: "client-compiled-flow" },
		]);
	} finally {
		Object.assign(globalThis, original);
	}
});
