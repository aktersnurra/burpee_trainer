// The rest's sink: a disc that holds the time and breathes. It fills out to a still ring on
// the nose breath and falls away from it on the mouth breath, so in and out read from across
// the room by the disc's size alone; nothing else on the screen moves.

const IN_SEC = 2;
const OUT_SEC = 3;
const TAU = Math.PI * 2;
// The last three seconds: the ring fades and the disc shrinks away.
const LAST_SEC = 3;
// The disc's radius, empty and full, as shares of the screen's short side (the width on a
// phone). Empty still holds the time; full is the ring.
const EMPTY = 0.2;
const FULL = 0.4;

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

// The disc's radius for a breath `x`.
export function discRadius(side, x) {
	return side * (EMPTY + (FULL - EMPTY) * x);
}

// The ring the disc fills to: a full breath.
export function ringRadius(side) {
	return side * FULL;
}

const BREATH = [186, 215, 255];
const rgba = (alpha) => `rgba(${BREATH[0]},${BREATH[1]},${BREATH[2]},${alpha})`;

// Draws the sink on `canvas` and reports the disc's radius in CSS pixels, so the time on it
// can turn to the on-fill colour where the disc covers it.
export function createSink(canvas, { onDisc = () => {}, reducedMotion = () => false } = {}) {
	const ctx = canvas.getContext?.("2d");
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
			const k = remainingSec > LAST_SEC || reduce ? 1 : easeInOut(remainingSec / LAST_SEC);
			const R = discRadius(side, x) * k;
			const X = W / 2;
			const Y = H / 2;
			ctx.clearRect(0, 0, W, H);
			onDisc(R / ratio);
			if (R <= 0) return;

			// The ring: still, and brighter as the disc reaches it.
			ctx.strokeStyle = rgba((0.45 + 0.4 * x) * k);
			ctx.lineWidth = side * 0.006;
			ctx.beginPath();
			ctx.arc(X, Y, ringRadius(side), 0, TAU);
			ctx.stroke();

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
