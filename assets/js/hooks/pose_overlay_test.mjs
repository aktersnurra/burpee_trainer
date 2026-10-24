import assert from "node:assert/strict";
import test from "node:test";
import { drawPoseOverlay } from "./pose_overlay.mjs";

test("pose lines and joints have bright ink and dark outlines independent of page colors", () => {
	const strokes = [];
	const fills = [];
	const arcs = [];
	const context = {
		clearRect() {}, save() {}, restore() {}, scale() {}, translate() {},
		beginPath() {}, moveTo() {}, lineTo() {},
		arc(...args) { arcs.push(args); },
		stroke() { strokes.push({ ink: this.strokeStyle, width: this.lineWidth }); },
		fill() { fills.push(this.fillStyle); },
	};
	const canvas = {
		getContext: () => context,
		getBoundingClientRect: () => ({ width: 200, height: 300 }),
	};
	const pose = { keypoints: [
		{ name: "left_shoulder", x: 50, y: 100, score: 0.9 },
		{ name: "right_shoulder", x: 150, y: 100, score: 0.9 },
		{ name: "nose", x: 100, y: 20, score: 0.1 },
	] };

	drawPoseOverlay(canvas, pose, { videoWidth: 200, videoHeight: 300 });

	assert.deepEqual(strokes, [
		{ ink: "#101820", width: 7 },
		{ ink: "#BFFF00", width: 3 },
		{ ink: "#101820", width: 2 },
		{ ink: "#101820", width: 2 },
	]);
	assert.deepEqual(fills, ["#BFFF00", "#BFFF00"]);
	assert.equal(arcs.length, 2);
	assert.equal(context.lineCap, "round");
	assert.equal(context.lineJoin, "round");
});
