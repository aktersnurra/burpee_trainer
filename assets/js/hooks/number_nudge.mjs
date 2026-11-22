// A number stepped up rises into place and one stepped down drops into it, so a step reads as a
// move rather than a swap: New's duration and reps, and the count on Finish. A held stepper
// restarts the move; a value being typed never moves; reduced motion keeps it still.
export const NUDGE_PX = 10;
const NUDGE_MS = 180;
const EASE_OUT = "cubic-bezier(.22, 1, .36, 1)";

export function nudge(el, from, to, win = globalThis) {
	const before = Number(from);
	const after = Number(to);
	if (from === "" || !Number.isFinite(before) || !Number.isFinite(after) || before === after) return;
	if (typeof el.animate !== "function") return;
	if (win.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return;

	const dir = after > before ? 1 : -1;
	el.getAnimations?.().forEach((animation) => animation.cancel());
	el.animate(
		[
			{ transform: `translateY(${dir * NUDGE_PX}px)`, opacity: 0.25 },
			{ transform: "none", opacity: 1 },
		],
		{ duration: NUDGE_MS, easing: EASE_OUT },
	);
}

// On an input the server steps (phx-hook="NumberNudge"); it needs an id.
const NumberNudge = {
	mounted() {
		this.value = this.el.value;
	},
	updated() {
		const before = this.value;
		this.value = this.el.value;
		if (this.el.ownerDocument.activeElement === this.el) return;
		nudge(this.el, before, this.value, this.win ?? globalThis);
	},
};

export default NumberNudge;
