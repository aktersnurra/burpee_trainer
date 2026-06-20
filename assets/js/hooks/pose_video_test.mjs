import test from "node:test";
import assert from "node:assert/strict";
import { isVideoFrameReady, webglAvailable } from "./pose_video.mjs";

test("isVideoFrameReady requires loaded video dimensions", () => {
	assert.equal(isVideoFrameReady({ readyState: 1, videoWidth: 640, videoHeight: 480 }), false);
	assert.equal(isVideoFrameReady({ readyState: 2, videoWidth: 0, videoHeight: 480 }), false);
	assert.equal(isVideoFrameReady({ readyState: 2, videoWidth: 640, videoHeight: 0 }), false);
	assert.equal(isVideoFrameReady({ readyState: 2, videoWidth: 640, videoHeight: 480 }), true);
});

test("webglAvailable checks webgl2 then webgl", () => {
	const calls = [];
	const documentLike = {
		createElement(tag) {
			assert.equal(tag, "canvas");
			return {
				getContext(name) {
					calls.push(name);
					return name === "webgl" ? {} : null;
				},
			};
		},
	};

	assert.equal(webglAvailable(documentLike), true);
	assert.deepEqual(calls, ["webgl2", "webgl"]);
});
