import test from "node:test";
import assert from "node:assert/strict";
import { breathAt, createAir, createSink, stepAir } from "./session_sink.mjs";

function seeded(seed) {
	let state = seed;
	return () => (state = (state * 16807) % 2147483647) / 2147483647;
}

const field = { R: 100, rMax: 420, W: 390 };

test("the breath is 2 s in and 3 s out, continuous at both turns", () => {
	assert.equal(breathAt(0), 0);
	assert.equal(breathAt(2), 1);
	assert.ok(Math.abs(breathAt(5) - breathAt(0)) < 1e-9);
	for (const turn of [2, 5]) {
		assert.ok(Math.abs(breathAt(turn - 1e-6) - breathAt(turn + 1e-6)) < 1e-4);
	}
	assert.ok(breathAt(0.5) > 0.5, "the in-breath is fast at first, like a sniff");
});

test("the air is conserved: specks wait in the disc or outside, never vanish", () => {
	for (let seed = 1; seed < 40; seed++) {
		const random = seeded(seed);
		const air = createAir(170, field, random);
		for (let step = 0; step < 600; step++) {
			const flow = (random() - 0.5) * 2;
			stepAir(air, { ...field, flow, dt: 1 / 60, sec: step / 60, live: random() < 0.9 }, random);
			assert.equal(air.length, 170);
			assert.ok(air.every((speck) => ["vis", "in", "out"].includes(speck.state)));
		}
	}
});

test("the in-breath draws the air inward and the out-breath pushes it out", () => {
	const meanRadius = (air) => {
		const visible = air.filter((speck) => speck.state === "vis");
		return visible.reduce((sum, speck) => sum + speck.r, 0) / visible.length;
	};
	for (const [flow, closer] of [
		[0.6, true],
		[-0.6, false],
	]) {
		const random = seeded(3);
		const air = createAir(170, field, random);
		const before = meanRadius(air);
		for (let step = 0; step < 10; step++) {
			stepAir(air, { ...field, flow, dt: 1 / 60, sec: step / 60, live: true }, random);
		}
		assert.equal(meanRadius(air) < before, closer);
	}
});

test("in the last three seconds no air enters or leaves the disc", () => {
	const random = seeded(9);
	const air = createAir(170, field, random);
	for (let step = 0; step < 120; step++) {
		stepAir(air, { ...field, flow: step < 60 ? 0.6 : -0.6, dt: 1 / 60, sec: step / 60, live: true }, random);
	}
	const states = air.map((speck) => speck.state);
	for (let step = 0; step < 180; step++) {
		stepAir(air, { ...field, flow: step < 90 ? 0.8 : -0.8, dt: 1 / 60, sec: step / 60, live: false }, random);
	}
	assert.deepEqual(
		air.map((speck) => speck.state),
		states,
	);
});

test("under reduced motion the disc holds its middle size and no air moves", () => {
	let strokes = 0;
	const ctx = new Proxy(
		{ stroke: () => (strokes += 1) },
		{ get: (target, key) => target[key] ?? (key.startsWith("create") ? () => ({ addColorStop() {} }) : () => {}), set: () => true },
	);
	const canvas = { clientWidth: 390, clientHeight: 844, width: 0, height: 0, getContext: () => ctx };
	const radii = [];
	const sink = createSink(canvas, { reducedMotion: () => true, onDisc: (radius) => radii.push(radius) });
	sink.start();
	for (let frame = 0; frame < 120; frame++) sink.frame(20 - frame / 60, frame * 16);
	assert.equal(strokes, 0);
	assert.ok(radii.every((radius) => radius === radii[0]));
});
