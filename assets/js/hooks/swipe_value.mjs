// A value you change by swiping it: right for more, left for less. The +/- buttons and the
// arrow keys beside it do the same, so nothing depends on the gesture.
import { createSwipeTracker } from "./swipe.mjs";

export function stepDirection(swipe) {
	if (swipe === "right") return "up";
	if (swipe === "left") return "down";
	return null;
}

export default {
	mounted() {
		this.tracker = createSwipeTracker({
			el: this.el,
			win: window,
			doc: document,
			onSwipe: (swipe) => {
				const dir = stepDirection(swipe);
				if (dir) this.pushEvent("step_workout_value", { field: this.el.dataset.field, dir });
			},
		});
		this.tracker.mount();
		this.onKey = (event) => {
			const dir = { ArrowRight: "up", ArrowUp: "up", ArrowLeft: "down", ArrowDown: "down" }[event.key];
			if (!dir) return;
			event.preventDefault();
			this.pushEvent("step_workout_value", { field: this.el.dataset.field, dir });
		};
		this.el.addEventListener("keydown", this.onKey);
	},
	destroyed() {
		this.tracker.destroy();
		this.el.removeEventListener("keydown", this.onKey);
	},
};
