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
			(this.listeners.get(type) || []).filter(
				(candidate) => candidate !== listener,
			),
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

const LOW_FRONT_GEOMETRY = Object.freeze({
	upright: { body: 3.2, hip: 2.35, torso: 0.85, wrist: 1.5 },
	lowering: { body: 2.1, hip: 1.65, torso: 0.45, wrist: 0.7 },
	floor: { body: 1.05, hip: 0.7, torso: 0.35, wrist: 0.45 },
	returning: { body: 1.65, hip: 1.1, torso: 0.55, wrist: 0.8 },
});

function lowFrontFrame(phase, tMs, { missingWorld = [] } = {}) {
	const geometry = LOW_FRONT_GEOMETRY[phase];
	if (!geometry) throw new Error(`unknown low-front phase: ${phase}`);

	const shoulderCenterX = Math.sqrt(1 - geometry.torso ** 2);
	const shoulderY = 0;
	const hipY = -geometry.torso;
	const ankleY = -geometry.body;
	const wristY = ankleY + geometry.wrist;
	const point = (name, x, y, world) => ({
		name,
		x,
		y,
		score: 0.9,
		...(missingWorld.includes(name) ? {} : { world }),
	});

	return {
		tMs,
		keypoints: [
			point("nose", 200, 50, { x: 0, y: 0.3, z: 0 }),
			point("left_shoulder", 150, 90, {
				x: shoulderCenterX - 0.5,
				y: shoulderY,
				z: 0,
			}),
			point("right_shoulder", 250, 90, {
				x: shoulderCenterX + 0.5,
				y: shoulderY,
				z: 0,
			}),
			point("left_wrist", 125, 220, { x: -0.7, y: wristY, z: 0 }),
			point("right_wrist", 275, 220, { x: 0.7, y: wristY, z: 0 }),
			point("left_hip", 160, 170, { x: -0.4, y: hipY, z: 0 }),
			point("right_hip", 240, 170, { x: 0.4, y: hipY, z: 0 }),
			point("left_knee", 165, 250, {
				x: -0.4,
				y: (hipY + ankleY) / 2,
				z: 0,
			}),
			point("right_knee", 235, 250, {
				x: 0.4,
				y: (hipY + ankleY) / 2,
				z: 0,
			}),
			point("left_ankle", 170, 340, { x: -0.4, y: ankleY, z: 0 }),
			point("right_ankle", 230, 340, { x: 0.4, y: ankleY, z: 0 }),
			point("left_foot_index", 165, 350, {
				x: -0.45,
				y: ankleY,
				z: 0.15,
			}),
			point("right_foot_index", 235, 350, {
				x: 0.45,
				y: ankleY,
				z: 0.15,
			}),
		],
	};
}

function lowFrontCycle(startMs) {
	return [
		lowFrontFrame("upright", startMs),
		lowFrontFrame("lowering", startMs + 100),
		lowFrontFrame("floor", startMs + 200),
		lowFrontFrame("returning", startMs + 300),
		lowFrontFrame("upright", startMs + 400),
	];
}

function absentFrames(startMs, durationMs) {
	return Array.from({ length: durationMs / 100 }, (_, index) => ({
		tMs: startMs + index * 100,
		keypoints: [],
	}));
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
		lowFrontFrame("upright", -800 + index * 100),
	);
	const scheduledFrames = [];
	let nowMs = 0;
	const impl = createPoseTracker(
		{ el: tracker },
		{
			controlledPoseFixture: [...readinessFrames, ...frames],
			mediaDevices: {
				getUserMedia: async () => assert.fail("fixture used camera"),
			},
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
			assert.ok(
				callback,
				"controlled tracker scheduled the next feature frame",
			);
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
		assert.equal(
			session.flow.mode,
			"workout_ready",
			JSON.stringify(session.flow),
		);
		tracker.dispatchEvent(
			new CustomEvent("pose-tracker:gesture-confirm", {
				bubbles: true,
				detail: { step: "workout_start" },
			}),
		);
		assert.equal(
			session.flow.mode,
			"workout_running",
			JSON.stringify(session.flow),
		);
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

test("the production tracker cannot activate a browser fixture from mutable global state", async () => {
	const tracker = await readFile(
		new URL("./pose_tracker_impl.mjs", import.meta.url),
		"utf8",
	);
	const app = await readFile(new URL("../app.js", import.meta.url), "utf8");
	const fixtureEntry = await readFile(
		new URL("../app_fixture.js", import.meta.url),
		"utf8",
	);
	const fixtureTracker = await readFile(
		new URL("./pose_tracker_fixture.js", import.meta.url),
		"utf8",
	);

	assert.doesNotMatch(tracker, /__burpeePoseFixture/);
	assert.doesNotMatch(app, /pose_tracker_fixture/);
	assert.match(fixtureEntry, /pose_tracker_fixture/);
	assert.match(fixtureTracker, /__burpeePoseFixture/);
});

test("fixture absence between macro-cycles leaves the rendered session warning-free and Save enabled", async () => {
	const root = await runControlledSessionFixture([
		...lowFrontCycle(0),
		...absentFrames(500, 2000),
		...lowFrontCycle(3500),
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
	assert.equal(
		root.querySelector("#session-live-status").textContent,
		"Workout complete",
	);
	assert.equal(
		root.querySelector("#session-save-btn").hasAttribute("disabled"),
		false,
	);
});
