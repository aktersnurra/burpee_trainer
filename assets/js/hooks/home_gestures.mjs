// Home's gesture: swipe right to swap the workout, left to put the drawer away.
// It opens what the drawer's button opens; the button stays for anyone who cannot swipe.
import { createSwipeTracker } from "./swipe.mjs";

// What a swipe does, given whether the drawer is open. `null` leaves the stroke alone.
export function gestureEvent(direction, { chooserOpen }) {
	if (chooserOpen) return direction === "left" ? "close_chooser" : null;
	return direction === "right" ? "open_chooser" : null;
}

export default {
	mounted() {
		this.tracker = createSwipeTracker({
			el: this.el,
			win: window,
			doc: document,
			// The drawer scrolls; fields and the table's expanders are taps.
			ignore: "[data-no-swipe], input, textarea, select",
			onSwipe: (direction) => {
				const event = gestureEvent(direction, {
					chooserOpen: this.el.dataset.chooserOpen === "true",
				});
				if (event) this.pushEvent(event, {});
			},
		});
		this.tracker.mount();
	},
	destroyed() {
		this.tracker.destroy();
	},
};
