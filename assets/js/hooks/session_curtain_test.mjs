import test from "node:test";
import assert from "node:assert/strict";
import { sessionCurtain } from "../session_curtain.mjs";

function fixture({ reduced = false, night = false, play = true } = {}) {
	const listeners = { doc: {}, win: {} };
	const timers = [];
	const animations = [];
	const body = { children: [], appendChild: (el) => body.children.push(el) };
	const pill = {
		disabled: false,
		closest: (s) => (s === ".home-play-action" ? pill : null),
		getBoundingClientRect: () => ({ top: 700, right: 243, bottom: 748, left: 147 }),
	};
	const state = { night, play };
	const doc = {
		body,
		documentElement: {},
		addEventListener: (name, callback) => (listeners.doc[name] = callback),
		querySelector: (s) =>
			s === ".session-night" ? (state.night ? {} : null) : s === ".home-play-action" && state.play ? pill : null,
		createElement: () => {
			const el = {
				style: {},
				setAttribute() {},
				remove: () => body.children.splice(body.children.indexOf(el), 1),
				animate: (frames, options) => {
					let done;
					const finished = new Promise((resolve) => (done = resolve));
					animations.push({ frames, options, done });
					return { finished };
				},
			};
			return el;
		},
	};
	const win = {
		innerWidth: 390,
		innerHeight: 844,
		matchMedia: () => ({ matches: reduced }),
		getComputedStyle: (el) => ({
			getPropertyValue: (name) => (el === doc.documentElement ? { "--motion-settle": "360ms", "--ease-out": "ease" }[name] : ""),
			borderRadius: "999px",
		}),
		addEventListener: (name, callback) => (listeners.win[name] = callback),
		setTimeout: (callback, ms) => timers.push({ callback, ms }) - 1,
		clearTimeout: () => {},
		requestAnimationFrame: (callback) => callback(),
	};
	sessionCurtain(doc, win);
	return {
		state,
		body,
		animations,
		tapPlay: () => listeners.doc.click({ target: pill }),
		loadStart: (kind = "redirect") => listeners.win["phx:page-loading-start"]({ detail: { kind } }),
		loadStop: () => listeners.win["phx:page-loading-stop"]({}),
	};
}

const settle = () => new Promise((resolve) => setImmediate(resolve));
const PILL = "inset(700px 147px 96px 147px round 999px)";
const FULL = "inset(0px 0px 0px 0px round 0px)";

test("Play grows into the runner: from the pill's box to the screen, gone once the runner is up", async () => {
	const f = fixture();
	f.tapPlay();
	assert.equal(f.body.children.length, 1);
	assert.deepEqual(f.animations[0].frames, [{ clipPath: PILL }, { clipPath: FULL }]);
	assert.equal(f.animations[0].options.duration, 360);

	f.loadStart();
	f.state.night = true;
	f.loadStop();
	await settle();
	// The curtain stays until the pill has grown.
	assert.equal(f.body.children.length, 1);
	f.animations[0].done();
	await settle();
	assert.equal(f.body.children.length, 0);
});

test("leaving a night screen shrinks the ink back into Home's Play pill", async () => {
	const f = fixture({ night: true });
	f.loadStart("redirect");
	assert.equal(f.body.children.length, 1);
	f.state.night = false;
	f.loadStop();
	assert.deepEqual(f.animations[0].frames, [{ clipPath: FULL }, { clipPath: PILL }]);
	f.animations[0].done();
	await settle();
	assert.equal(f.body.children.length, 0);
});

test("reduced motion, light screens and patches just update", () => {
	const reduced = fixture({ reduced: true, night: true });
	reduced.tapPlay();
	reduced.loadStart();
	assert.equal(reduced.body.children.length, 0);

	const light = fixture();
	light.loadStart("redirect");
	assert.equal(light.body.children.length, 0);

	const patch = fixture({ night: true });
	patch.loadStart("patch");
	assert.equal(patch.body.children.length, 0);
});
