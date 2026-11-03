// Home's gesture on a tablet: swipe right to swap the workout, left to put the drawer away.
// It opens what the drawer's button opens; the button stays for anyone who cannot swipe. On a
// phone the list is a sheet from the bottom, opened by its button and dragged down to close
// (SheetDrag), so a sideways stroke does nothing.
import { createSwipeTracker } from "./swipe.mjs";
import { PHONE } from "./sheet_drag.mjs";

// What a swipe does, given whether the drawer is open. `null` leaves the stroke alone.
export function gestureEvent(direction, { chooserOpen, phone = false }) {
	if (phone) return null;
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
					phone: Boolean(window.matchMedia?.(PHONE)?.matches),
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
