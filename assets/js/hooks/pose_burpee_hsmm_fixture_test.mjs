import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

import SessionHook from "./session_hook.js";
import { createPoseTracker } from "./pose_tracker_impl.mjs";

class FixtureElement {
	constructor(tagName = "div") {
		this.tagName = tagName;
		this.children = [];
		this.parentElement = null;
		this.id = "";
		this.dataset = {};
		this.attributes = new Map();
		this.listeners = new Map();
		this.className = "";
		this.textContent = "";
		this.value = "";
		this.hidden = false;
		this.style = {};
		const classes = new Set();
		this.classList = {
			add: (...names) => names.forEach((name) => classes.add(name)),
			remove: (...names) => names.forEach((name) => classes.delete(name)),
			contains: (name) => classes.has(name),
		};
	}

	append(...children) {
		for (const child of children) {
			child.parentElement = this;
			this.children.push(child);
		}
	}

	setAttribute(name, value) {
		this.attributes.set(name, String(value));
	}

	getAttribute(name) {
		return this.attributes.get(name) ?? null;
	}

	hasAttribute(name) {
		return this.attributes.has(name);
	}

	removeAttribute(name) {
		this.attributes.delete(name);
	}

	toggleAttribute(name, force) {
		if (force) this.setAttribute(name, "");
		else this.removeAttribute(name);
	}

	focus() {}

	addEventListener(type, listener) {
		this.listeners.set(type, [...(this.listeners.get(type) || []), listener]);
	}

	removeEventListener(type, listener) {
		this.listeners.set(
			type,
			(this.listeners.get(type) || []).filter((candidate) => candidate !== listener),
		);
	}

	dispatchEvent(event) {
		if (!event.target) event.target = this;
		event.currentTarget = this;
		for (const listener of this.listeners.get(event.type) || []) {
			listener.call(this, event);
		}
		if (event.bubbles && this.parentElement) {
			return this.parentElement.dispatchEvent(event);
		}
		return true;
	}

	querySelector(selector) {
		if (selector.startsWith("#") && !selector.includes(" ")) {
			return this.findById(selector.slice(1));
		}
		return null;
	}

	querySelectorAll(selector) {
		if (selector !== "[data-session-panel]") return [];
		const panels = [];
		const visit = (element) => {
			if (element.hasAttribute("data-session-panel")) panels.push(element);
			for (const child of element.children) visit(child);
		};
		visit(this);
		return panels;
	}

	closest(selector) {
		if (!selector.startsWith("#")) return null;
		let element = this;
		while (element) {
			if (element.id === selector.slice(1)) return element;
			element = element.parentElement;
		}
		return null;
	}

	findById(id) {
		if (this.id === id) return this;
		for (const child of this.children) {
			const found = child.findById(id);
			if (found) return found;
		}
		return null;
	}
}

function readyKeypoints() {
	return {
		left_shoulder: { score: 0.9, x: 0.4, y: 0.2 },
		right_shoulder: { score: 0.9, x: 0.6, y: 0.2 },
		left_hip: { score: 0.9, x: 0.43, y: 0.5 },
		right_hip: { score: 0.9, x: 0.57, y: 0.5 },
		left_knee: { score: 0.9, x: 0.45, y: 0.7 },
		right_knee: { score: 0.9, x: 0.55, y: 0.7 },
		left_ankle: { score: 0.9, x: 0.45, y: 0.9 },
	};
}

function feature(tMs, values, confidence = 0.9) {
	return {
		tMs,
		poseConfidence: confidence,
		visibleFraction: confidence,
		macroLandmarkConfidence: confidence,
		keypoints: readyKeypoints(),
		...values,
	};
}

function completeCycle(startMs) {
	return [
		feature(startMs, {
			wristToAnkle: 1.25,
			shoulderToAnkle: 2.1,
			torsoUprightness: 0.9,
			hipToKnee: 0.9,
			dWristToAnkle: 0,
			dShoulderToAnkle: 0,
		}),
		feature(startMs + 100, {
			wristToAnkle: 0.55,
			shoulderToAnkle: 1.2,
			torsoUprightness: 0.55,
			hipToKnee: 0.6,
			dWristToAnkle: -1.4,
			dShoulderToAnkle: -1.1,
		}),
		feature(startMs + 200, {
			wristToAnkle: 0.16,
			shoulderToAnkle: 0.38,
			torsoUprightness: 0.12,
			hipToKnee: 0.52,
			dWristToAnkle: 0,
			dShoulderToAnkle: 0,
		}),
		feature(startMs + 300, {
			wristToAnkle: 0.48,
			shoulderToAnkle: 0.72,
			torsoUprightness: 0.45,
			hipToKnee: 0.3,
			dWristToAnkle: 1.2,
			dShoulderToAnkle: 1.4,
		}),
		feature(startMs + 400, {
			wristToAnkle: 1.25,
			shoulderToAnkle: 2.1,
			torsoUprightness: 0.9,
			hipToKnee: 0.9,
			dWristToAnkle: 0,
			dShoulderToAnkle: 0,
		}),
	];
}

function absentFrames(startMs, durationMs) {
	return Array.from({ length: durationMs / 100 }, (_, index) =>
		feature(startMs + index * 100, {}, 0.1),
	);
}

function fixtureRoot() {
	const root = new FixtureElement();
	root.id = "burpee-session";
	root.dataset.sessionProgram = JSON.stringify({
		events: [{ kind: "work", reps: 2, sec_per_rep: 5 }],
	});
	root.dataset.planId = "fixture-plan";
	root.dataset.programHash = "fixture-program";
	root.dataset.clientSessionId = "fixture-session";

	for (const id of [
		"session-capture-choice",
		"session-camera-status",
		"session-camera-setup",
		"session-warmup-choice",
		"session-workout-ready",
		"session-runner-client",
		"session-completion-review",
	]) {
		const panel = new FixtureElement("section");
		panel.id = id;
		panel.setAttribute("data-session-panel", "");
		root.append(panel);
	}

	for (const [id, tag = "div"] of [
		["camera-status-starting"],
		["camera-status-error"],
		["camera-setup-arming"],
		["camera-setup-ready"],
		["warmup-manual-controls"],
		["warmup-tracked-instruction"],
		["warmup-skip-countdown"],
		["workout-ready-btn", "button"],
		["workout-ready-instruction"],
		["workout-ready-continue", "button"],
		["session-report-pending-status"],
		["session-report-pending-retry", "button"],
		["session-live-status"],
		["session-actual-reps"],
		["session-planned-reps"],
		["session-actual-duration"],
		["completion-reps-input", "input"],
		["completion-duration-input", "input"],
		["completion-note-input", "textarea"],
		["session-save-btn", "button"],
		["session-save-errors"],
		["completion-reps-error"],
		["completion-duration-error"],
		["completion-note-error"],
		["session-pause-actions"],
		["finish-early-btn", "button"],
		["session-abort-btn", "button"],
		["workout_session_burpee_type", "input"],
	]) {
		const element = new FixtureElement(tag);
		element.id = id;
		if (id === "workout_session_burpee_type") element.value = "six_count";
		root.append(element);
	}

	return root;
}

function trackerElement(root) {
	const tracker = new FixtureElement();
	tracker.id = "pose-tracker";
	const video = new FixtureElement("video");
	video.id = "pose-tracker-preview";
	video.videoWidth = 640;
	video.videoHeight = 480;
	video.play = async () => {};
	video.getBoundingClientRect = () => ({ width: 320, height: 240 });
	const canvas = new FixtureElement("canvas");
	canvas.id = "pose-tracker-canvas";
	canvas.getBoundingClientRect = () => ({ width: 320, height: 240 });
	canvas.getContext = () => ({ setTransform() {}, clearRect() {} });
	tracker.append(video, canvas);
	root.append(tracker);
	return tracker;
}

async function runControlledSessionFixture(frames) {
	const original = {
		CustomEvent: globalThis.CustomEvent,
		document: globalThis.document,
		requestAnimationFrame: globalThis.requestAnimationFrame,
		cancelAnimationFrame: globalThis.cancelAnimationFrame,
		setTimeout: globalThis.setTimeout,
		clearTimeout: globalThis.clearTimeout,
	};
	const documentListeners = new Map();
	globalThis.CustomEvent = class {
		constructor(type, init = {}) {
			this.type = type;
			this.detail = init.detail;
			this.bubbles = Boolean(init.bubbles);
		}
	};
	globalThis.document = {
		visibilityState: "visible",
		documentElement: {},
		createElement: (tagName) => new FixtureElement(tagName),
		addEventListener(type, listener) {
			documentListeners.set(type, [
				...(documentListeners.get(type) || []),
				listener,
			]);
		},
		removeEventListener(type, listener) {
			documentListeners.set(
				type,
				(documentListeners.get(type) || []).filter(
					(candidate) => candidate !== listener,
				),
			);
		},
		dispatchEvent(event) {
			for (const listener of documentListeners.get(event.type) || []) {
				listener.call(this, event);
			}
		},
	};
	globalThis.requestAnimationFrame = () => 1;
	globalThis.cancelAnimationFrame = () => {};
	globalThis.setTimeout = () => 1;
	globalThis.clearTimeout = () => {};

	const root = fixtureRoot();
	const tracker = trackerElement(root);
	const session = {
		...SessionHook,
		el: root,
		openSessionStore: async () => null,
		requestBeginSession() {
			this.dispatchFlow({ type: "SESSION_BEGIN_ACKNOWLEDGED" });
		},
		requestReportPending() {
			this.dispatchFlow({ type: "REPORT_PENDING_ACKNOWLEDGED" });
		},
	};
	const readinessFrames = Array.from({ length: 8 }, (_, index) =>
		feature(-800 + index * 100, {
			wristToAnkle: 1.25,
			shoulderToAnkle: 2.1,
			torsoUprightness: 0.9,
			hipToKnee: 0.9,
			dWristToAnkle: 0,
			dShoulderToAnkle: 0,
		}),
	);
	const scheduledFrames = [];
	let nowMs = 0;
	const impl = createPoseTracker(
		{ el: tracker },
		{
			controlledPoseFixture: [...readinessFrames, ...frames],
			mediaDevices: { getUserMedia: async () => assert.fail("fixture used camera") },
			createBlazePoseDetector: async () =>
				assert.fail("fixture loaded detector"),
			now: () => nowMs,
			requestAnimationFrame(callback) {
				scheduledFrames.push(callback);
				return scheduledFrames.length;
			},
			cancelAnimationFrame() {},
			setTimeout: () => 1,
			clearTimeout() {},
		},
	);
	const flush = async () => {
		await Promise.resolve();
		await Promise.resolve();
	};
	const runFrames = async (count) => {
		for (let index = 0; index < count; index += 1) {
			nowMs += 100;
			const callback = scheduledFrames.shift();
			assert.ok(callback, "controlled tracker scheduled the next feature frame");
			await callback();
			await flush();
		}
	};

	try {
		session.mounted();
		session.audio = {
			ensureRunning() {},
			stop() {},
			close() {},
			playLeadBeep() {},
			playRepBeep() {},
		};
		session.wakeLock = {
			acquire() {},
			release() {},
			reacquireWhenVisible() {},
		};
		await impl.mounted();
		session.dispatchFlow({ type: "CHOOSE_CAMERA" });
		await flush();
		await runFrames(readinessFrames.length - 1);

		tracker.dispatchEvent(
			new CustomEvent("pose-tracker:gesture-confirm", {
				bubbles: true,
				detail: { step: "camera_setup" },
			}),
		);
		session.dispatchFlow({ type: "WARMUP_TIMEOUT", step: "warmup" });
		assert.equal(session.flow.mode, "workout_ready", JSON.stringify(session.flow));
		tracker.dispatchEvent(
			new CustomEvent("pose-tracker:gesture-confirm", {
				bubbles: true,
				detail: { step: "workout_start" },
			}),
		);
		assert.equal(session.flow.mode, "workout_running", JSON.stringify(session.flow));
		session.beginSegment();
		await runFrames(frames.length);
		session.dispatchSegment({ type: "TICK", elapsedSec: 10 });
		await flush();
		await flush();

		return root;
	} finally {
		impl.destroyed();
		session.destroyed();
		Object.assign(globalThis, original);
	}
}

test("the app bundle has no calibration or template matcher dependency", async () => {
	const app = await readFile(new URL("../app.js", import.meta.url), "utf8");
	assert.doesNotMatch(
		app,
		/pose_(?:calibration_button|template_calibration|template_matcher)/,
	);
});

test("fixture absence between macro-cycles leaves the rendered session warning-free and Save enabled", async () => {
	const root = await runControlledSessionFixture([
		...completeCycle(0),
		...absentFrames(500, 2000),
		...completeCycle(3500),
	]);

	assert.equal(
		root.querySelector("#session-actual-reps").textContent,
		"2",
		"the controlled tracker must render its counted reps in the session completion",
	);
	assert.doesNotMatch(
		root.querySelector("#session-live-status").textContent,
		/tracking degraded|out of frame/i,
	);
	assert.equal(root.querySelector("#session-live-status").textContent, "Workout complete");
	assert.equal(root.querySelector("#session-save-btn").hasAttribute("disabled"), false);
});
