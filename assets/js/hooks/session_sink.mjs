// The rest's sink: a disc that holds the time, and air that whirls into it on the nose breath
// and out of it on the mouth breath, like water in a sink. The air is a fixed set of specks
// moved by the breath: their speed toward or away from the disc is the disc's own rate of
// change, so the air rushes in on the sniff, coasts, stops at the turn and is pushed out.
// The same specks go in and come back out; nothing appears or vanishes on a timer.

const IN_SEC = 2;
const OUT_SEC = 3;
const TAU = Math.PI * 2;
// The last three seconds: the air stops entering and leaving, and the disc shrinks away.
const LAST_SEC = 3;
const TRAIL = 15;

const clamp = (x) => Math.min(Math.max(x, 0), 1);
const easeInOut = (x) => 0.5 - 0.5 * Math.cos(Math.PI * clamp(x));
const easeOutCubic = (x) => 1 - (1 - clamp(x)) ** 3;

// How full the breath is at `phaseSec` into the rest, 0 to 1: in through the nose, fast at
// first, then out through the mouth, longer.
export function breathAt(phaseSec) {
	const cycle = IN_SEC + OUT_SEC;
	const phase = ((phaseSec % cycle) + cycle) % cycle;
	return phase < IN_SEC
		? easeOutCubic(phase / IN_SEC)
		: 1 - easeInOut((phase - IN_SEC) / OUT_SEC);
}

// The disc's radius for a breath `x`, between 23% and 32% of the screen's short side (the
// width on a phone).
export function discRadius(side, x) {
	return side * (0.23 + 0.09 * x);
}

// `count` specks spread between the disc and the edge, each a little different.
export function createAir(count, { R, rMax }, random = Math.random) {
	return Array.from({ length: count }, () => ({
		r: R * 1.4 + (rMax - R * 1.4) * Math.sqrt(random()),
		th: random() * TAU,
		seed: random(),
		speed: 0.7 + 0.6 * random(),
		size: 0.55 + 0.85 * random(),
		state: "vis",
		alpha: 1,
		trail: [],
	}));
}

// Moves the air one step. `flow` is the breath's rate of change (per second, positive
// breathing in). Specks that reach the disc wait in it; specks pushed past rMax wait outside;
// each breath releases waiting specks the other way. With `live` false nothing crosses.
export function stepAir(air, { R, rMax, W, flow, dt, sec, live }, random = Math.random) {
	const inhale = flow > 0;
	const magnitude = Math.abs(flow);
	for (const speck of air) {
		if (speck.state === "in") {
			if (live && !inhale && random() < magnitude * dt * 2.4) {
				Object.assign(speck, { state: "vis", r: R * 0.92, th: random() * TAU, alpha: 1, trail: [] });
			}
			continue;
		}
		if (speck.state === "out") {
			if (live && inhale && random() < magnitude * dt * 2.4) {
				const r = rMax * (0.62 + 0.45 * random());
				Object.assign(speck, { state: "vis", r, th: random() * TAU, alpha: 0, trail: [] });
			}
			continue;
		}
		const near = (R / Math.max(speck.r, R * 0.5)) ** 0.35;
		const radial =
			-flow * rMax * 0.78 * near * speck.speed + W * 0.022 * Math.sin(sec * 1.7 + speck.seed * 40);
		const angular =
			(0.16 + 2.4 * magnitude) * (R / speck.r) ** 0.8 * speck.speed +
			0.1 * Math.sin(sec * 1.3 + speck.seed * 60);
		speck.r += radial * dt;
		speck.th += angular * dt;
		if (speck.alpha < 1) speck.alpha = Math.min(1, speck.alpha + dt * 2.5);
		if (!live) speck.r = Math.min(Math.max(speck.r, R * 0.9), rMax * 1.1);
		else if (speck.r < R * 0.9) speck.state = "in";
		else if (speck.r > rMax * 1.1) speck.state = "out";
	}
}

const BREATH = [186, 215, 255];
const rgba = (alpha) => `rgba(${BREATH[0]},${BREATH[1]},${BREATH[2]},${alpha})`;

// Draws the sink on `canvas` and reports the disc's radius in CSS pixels, so the time on it
// can turn to the on-fill colour where the disc covers it.
export function createSink(canvas, { onDisc = () => {}, reducedMotion = () => false } = {}) {
	const ctx = canvas.getContext?.("2d");
	let air = null;
	let breathSec = 0;
	let last = null;

	const fit = () => {
		const ratio = Math.min(globalThis.devicePixelRatio || 1, 2);
		const width = Math.round(canvas.clientWidth * ratio);
		const height = Math.round(canvas.clientHeight * ratio);
		if (canvas.width !== width || canvas.height !== height) {
			canvas.width = width;
			canvas.height = height;
		}
		return ratio;
	};

	return {
		// A new rest: the breath starts in.
		start() {
			breathSec = 0;
			last = null;
			air = null;
		},
		// The clock stopped (pause or a hidden page): the next frame does not jump.
		hold() {
			last = null;
		},
		frame(remainingSec, now = performance.now()) {
			if (!ctx) return;
			const ratio = fit();
			const W = canvas.width;
			const H = canvas.height;
			const side = Math.min(W, H);
			const reduce = reducedMotion();
			const dt = last === null ? 0 : Math.min((now - last) / 1000, 0.1);
			last = now;
			breathSec += dt;

			const x = reduce ? 0.5 : breathAt(breathSec);
			const live = !reduce && remainingSec > LAST_SEC;
			const k = remainingSec > LAST_SEC || reduce ? 1 : easeInOut(remainingSec / LAST_SEC);
			const R = discRadius(side, x) * k;
			const X = W / 2;
			const Y = H / 2;
			const rMax = Math.hypot(W, H) / 2;
			ctx.clearRect(0, 0, W, H);
			onDisc(R / ratio);
			if (R <= 0) return;

			const glow = ctx.createRadialGradient(X, Y, R * 0.6, X, Y, R * 2);
			glow.addColorStop(0, rgba((0.22 * x + 0.06) * k));
			glow.addColorStop(1, rgba(0));
			ctx.fillStyle = glow;
			ctx.fillRect(0, 0, W, H);

			if (!reduce) {
				const field = { R: discRadius(side, x), rMax, W: side };
				air ??= createAir(170, field);
				const step = Math.max(dt, 1 / 120);
				const flow = (breathAt(breathSec) - breathAt(breathSec - step)) / step;
				stepAir(air, { ...field, flow: dt === 0 ? 0 : flow, dt, sec: breathSec, live });
				drawAir(ctx, air, X, Y, side, k);
			}

			const body = ctx.createRadialGradient(X, Y - R * 0.3, R * 0.1, X, Y, R);
			body.addColorStop(0, "#D3E6FF");
			body.addColorStop(1, "#A9C9F3");
			ctx.fillStyle = body;
			ctx.beginPath();
			ctx.arc(X, Y, R, 0, TAU);
			ctx.fill();
		},
	};
}

function drawAir(ctx, air, X, Y, W, k) {
	ctx.lineCap = "round";
	for (const speck of air) {
		if (speck.state !== "vis") {
			speck.trail.length = 0;
			continue;
		}
		speck.trail.unshift([X + speck.r * Math.cos(speck.th), Y + speck.r * Math.sin(speck.th)]);
		if (speck.trail.length > TRAIL) speck.trail.pop();
		const trail = speck.trail;
		for (let i = 0; i < trail.length - 1; i++) {
			const u = i / (trail.length - 1);
			ctx.strokeStyle = rgba(speck.alpha * k * speck.size * 0.8 * (1 - u));
			ctx.lineWidth = W * (0.003 + 0.005 * speck.size) * (1 - 0.7 * u);
			ctx.beginPath();
			ctx.moveTo(trail[i][0], trail[i][1]);
			ctx.lineTo(trail[i + 1][0], trail[i + 1][1]);
			ctx.stroke();
		}
	}
}
