import test from "node:test";
import assert from "node:assert/strict";
import { breathAt, createSink, discRadius, ringRadius } from "./session_sink.mjs";

// A canvas that records nothing but lets the sink draw, and the disc's radius each frame.
function sinkOn({ reduce = false } = {}) {
	const ctx = new Proxy(
		{},
		{ get: (_, key) => (String(key).startsWith("create") ? () => ({ addColorStop() {} }) : () => {}), set: () => true },
	);
	const canvas = { clientWidth: 390, clientHeight: 844, width: 0, height: 0, getContext: () => ctx };
	const radii = [];
	const sink = createSink(canvas, { reducedMotion: () => reduce, onDisc: (radius) => radii.push(radius) });
	sink.start();
	return { sink, radii };
}

test("the breath is 2 s in and 3 s out, continuous at both turns", () => {
	assert.equal(breathAt(0), 0);
	assert.equal(breathAt(2), 1);
	assert.ok(Math.abs(breathAt(5) - breathAt(0)) < 1e-9);
	for (const turn of [2, 5]) {
		assert.ok(Math.abs(breathAt(turn - 1e-6) - breathAt(turn + 1e-6)) < 1e-4);
	}
	assert.ok(breathAt(0.5) > 0.5, "the in-breath is fast at first, like a sniff");
});

test("the disc fills to the ring on the in-breath, a swing readable across the room", () => {
	assert.equal(discRadius(390, 1), ringRadius(390));
	assert.ok(discRadius(390, 1) >= 1.8 * discRadius(390, 0));
	assert.ok(ringRadius(390) * 2 < 390, "the ring stays on the screen");
});

test("the disc grows for the two seconds in and shrinks for the three out", () => {
	const { sink, radii } = sinkOn();
	for (let frame = 0; frame <= 300; frame++) sink.frame(30, frame * (1000 / 60));
	const at = (sec) => radii[Math.round(sec * 60)];
	for (let sec = 0.25; sec <= 2; sec += 0.25) assert.ok(at(sec) > at(sec - 0.25), `in at ${sec}`);
	for (let sec = 2.25; sec <= 5; sec += 0.25) assert.ok(at(sec) < at(sec - 0.25), `out at ${sec}`);
});

test("in the last three seconds the disc shrinks away", () => {
	const { sink, radii } = sinkOn();
	for (const left of [3, 2, 1, 0]) sink.frame(left, 0);
	assert.ok(radii[0] > radii[1] && radii[1] > radii[2] && radii[2] > radii[3]);
	assert.equal(radii[3], 0);
});

test("under reduced motion the disc holds its middle size", () => {
	const { sink, radii } = sinkOn({ reduce: true });
	for (let frame = 0; frame < 120; frame++) sink.frame(20 - frame / 60, frame * 16);
	assert.ok(radii.every((radius) => radius === radii[0]));
	assert.ok(radii[0] > discRadius(390, 0) && radii[0] < discRadius(390, 1));
});
