// Home's gestures: swipe right to swap the workout, swipe up for Edit and New.
// Both open what the buttons open; the buttons stay for anyone who cannot swipe.
import { createSwipeTracker } from "./swipe.mjs";
import { noteSwipe } from "./home_hint.mjs";

// What a swipe does, given what is open. `null` leaves the stroke alone. Swap is the swipe right
// anywhere; Edit and New wait for the swipe up on a workout that has been opened.
export function gestureEvent(direction, { chooserOpen, optionsOpen, expanded }) {
	if (chooserOpen) return direction === "left" ? "close_chooser" : null;
	if (optionsOpen) return direction === "down" ? "close_options" : null;
	if (direction === "right") return "open_chooser";
	if (direction === "up" && expanded) return "open_options";
	return null;
}

export default {
	mounted() {
		this.tracker = createSwipeTracker({
			el: this.el,
			win: window,
			doc: document,
			// The drawer scrolls and the sheet has its own buttons; fields and the table's
			// expanders are taps.
			ignore: "[data-no-swipe], input, textarea, select",
			onSwipe: (direction) => {
				const event = gestureEvent(direction, {
					chooserOpen: this.el.dataset.chooserOpen === "true",
					optionsOpen: this.el.dataset.optionsOpen === "true",
					expanded: this.el.dataset.expanded === "true",
				});
				if (event) {
					noteSwipe();
					this.pushEvent(event, {});
				}
			},
		});
		this.tracker.mount();
	},
	destroyed() {
		this.tracker.destroy();
	},
};
