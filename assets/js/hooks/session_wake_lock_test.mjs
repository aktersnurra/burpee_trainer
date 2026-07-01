import test from "node:test";
import assert from "node:assert/strict";
import { SessionWakeLock } from "./session_wake_lock.mjs";

test("active wake lock reacquires when the browser releases it", async () => {
	const releaseListeners = [];
	let requests = 0;
	let visible = "visible";

	globalThis.document = {
		get visibilityState() {
			return visible;
		},
	};

	Object.defineProperty(globalThis, "navigator", {
		value: {
			wakeLock: {
				async request(type) {
					assert.equal(type, "screen");
					requests += 1;
					return {
						addEventListener(event, callback) {
							assert.equal(event, "release");
							releaseListeners.push(callback);
						},
						async release() {},
					};
				},
			},
		},
		configurable: true,
	});

	const wakeLock = new SessionWakeLock();
	await wakeLock.acquire();
	assert.equal(requests, 1);
	assert.equal(releaseListeners.length, 1);

	releaseListeners[0]();
	await Promise.resolve();

	assert.equal(requests, 2);

	visible = "hidden";
	releaseListeners[1]();
	await Promise.resolve();

	assert.equal(requests, 2);

	wakeLock.release();
	visible = "visible";
	releaseListeners[1]();
	await Promise.resolve();

	assert.equal(requests, 2);
});
