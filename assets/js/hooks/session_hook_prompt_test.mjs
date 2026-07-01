import test from "node:test";
import assert from "node:assert/strict";
import SessionHook from "./session_hook.js";

class FakeElement {
	constructor(tagName = "div") {
		this.tagName = tagName;
		this.children = [];
		this.id = "";
		this.type = "";
		this.className = "";
		this.textContent = "";
		this.style = {};
		this.attributes = new Map();
	}

	setAttribute(name, value) {
		this.attributes.set(name, String(value));
	}

	removeAttribute(name) {
		this.attributes.delete(name);
	}

	hasAttribute(name) {
		return this.attributes.has(name);
	}

	append(...children) {
		for (const child of children) this.appendChild(child);
	}

	appendChild(child) {
		this.children.push(child);
		return child;
	}

	replaceChildren(...children) {
		this.children = [];
		this.append(...children);
	}

	querySelector(selector) {
		if (selector.startsWith("#")) {
			return this.findById(selector.slice(1));
		}

		return null;
	}

	findById(id) {
		if (this.id === id) return this;

		for (const child of this.children) {
			const found = child.findById?.(id);
			if (found) return found;
		}

		return null;
	}
}

globalThis.document = {
	createElement(tagName) {
		return new FakeElement(tagName);
	},
};

function hookContext() {
	const root = new FakeElement("div");
	const runner = new FakeElement("div");
	runner.id = "session-runner-client";
	root.appendChild(runner);

	return {
		el: root,
		renderer: { resetReady() {} },
		audio: { stop() {} },
		rafId: null,
		startTime: null,
		countdownCount: null,
		countdownPaused: false,
	};
}

test("finish early stays disabled while workout countdown is paused", () => {
	const ctx = hookContext();
	const actions = new FakeElement("div");
	actions.id = "session-pause-actions";
	const finishEarly = new FakeElement("button");
	finishEarly.id = "finish-early-btn";
	ctx.el.append(actions, finishEarly);
	ctx.activeSegment = "workout";
	ctx.paused = false;
	ctx.countdownPaused = true;
	ctx.startTime = null;

	SessionHook.updatePauseActionsVisibility.call(ctx);

	assert.equal(finishEarly.hasAttribute("disabled"), true);
});

test("finish early uses paused segment elapsed time", () => {
	const ctx = hookContext();
	let finishEvent = null;
	ctx.activeSegment = "workout";
	ctx.countdownCount = null;
	ctx.startTime = 1000;
	ctx.segment = { clock: { elapsedSec: 42 } };
	ctx.dispatchSegment = (event) => {
		finishEvent = event;
	};
	globalThis.confirm = () => true;

	SessionHook.onFinishEarly.call(ctx);

	assert.equal(finishEvent.type, "FINISH_EARLY");
	assert.equal(finishEvent.elapsedSec, 42);
});

test("skipped warmup renders neutral workout-ready copy", () => {
	const ctx = hookContext();

	SessionHook.showWorkoutReadyPrompt.call({
		...ctx,
		showWorkoutStartPrompt: SessionHook.showWorkoutStartPrompt,
	});

	assert.equal(
		ctx.el.querySelector("#workout-ready-btn").textContent,
		"Start workout",
	);
	assert.equal(
		ctx.el.querySelector("#start-overlay-title").textContent,
		"Ready when you are",
	);
});

test("warmup prompt renders actionable warmup buttons after capture choice", () => {
	const ctx = hookContext();

	SessionHook.showCapturePrompt.call(ctx);
	assert.equal(
		ctx.el.querySelector("#capture-tracked-btn").textContent,
		"Track with camera",
	);
	assert.ok(ctx.el.querySelector("#capture-timed-btn"));

	SessionHook.showWarmupPrompt.call(ctx);

	assert.ok(ctx.el.querySelector("#warmup-yes-btn"));
	assert.ok(ctx.el.querySelector("#warmup-skip-btn"));
	assert.equal(ctx.el.querySelector("#capture-tracked-btn"), null);
	assert.equal(ctx.el.querySelector("#capture-timed-btn"), null);
});

test("starting tracked camera setup tells the server the setup card can close", () => {
	const events = [];
	const flowEvents = [];
	const ctx = {
		pushEvent(name, payload) {
			events.push({ name, payload });
		},
		dispatchFlow(event) {
			flowEvents.push(event);
		},
	};

	SessionHook.onCameraSetupStart.call(ctx);

	assert.deepEqual(events, [{ name: "camera_setup_started", payload: {} }]);
	assert.deepEqual(flowEvents, [{ type: "CAMERA_SETUP_READY" }]);
});
