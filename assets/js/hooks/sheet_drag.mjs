// A bottom sheet that follows the finger down, as iOS sheets do. On a phone the drawer is a sheet
// (`max-width: 600px`); a downward drag that starts with its list at the top moves the sheet with
// the finger, and on release it either closes (far enough, or flicked) or settles back. Closing
// clicks the sheet's own close button (`data-close`), so it closes exactly as a tap would; its
// scrim (`data-backdrop`) fades as it goes. The drawer and the coach's memory are such sheets.

export const PHONE = "(max-width: 600px)";
// Movement before a stroke counts as a drag rather than a tap or a scroll.
export const DRAG_START_PX = 6;
// Released past this share of its height, or flicked faster than this, the sheet closes.
export const CLOSE_SHARE = 0.25;
export const CLOSE_PX_PER_MS = 0.5;

export function dragOutcome({ dy, ms, height }) {
	if (dy <= 0) return "stay";
	if (dy >= height * CLOSE_SHARE) return "close";
	return dy / Math.max(ms, 1) >= CLOSE_PX_PER_MS ? "close" : "stay";
}

export function createSheetDrag({ el, win, doc, now = Date.now }) {
	let start = null;
	let dragging = false;

	const phone = () => Boolean(win.matchMedia?.(PHONE)?.matches);
	const backdrop = () => doc.querySelector(el.dataset.backdrop);

	const follow = (dy) => {
		el.style.transition = "none";
		el.style.transform = `translateY(${dy}px)`;
		const scrim = backdrop();
		if (scrim) scrim.style.opacity = String(Math.max(0, 1 - dy / el.offsetHeight));
	};

	// The sheet goes back to the stylesheet's place, open or (once the close button has hidden it)
	// closed; the next frame transitions there from where the finger left it.
	const letGo = (outcome) => {
		el.style.transition = "";
		el.style.transform = "";
		const scrim = backdrop();
		if (scrim) scrim.style.opacity = "";
		if (outcome === "close") doc.querySelector(el.dataset.close)?.click();
	};

	const onStart = (event) => {
		start = null;
		dragging = false;
		if (!phone() || event.touches.length !== 1 || el.scrollTop > 0) return;
		start = { y: event.touches[0].clientY, at: now() };
	};

	const onMove = (event) => {
		if (!start) return;
		const dy = event.touches[0].clientY - start.y;
		if (!dragging) {
			// Up is a scroll of the list; only a pull down from the top moves the sheet.
			if (dy < -DRAG_START_PX) start = null;
			if (dy <= DRAG_START_PX) return;
			dragging = true;
		}
		event.preventDefault();
		follow(Math.max(0, dy));
	};

	const onEnd = (event) => {
		if (!start) return;
		const wasDragging = dragging;
		const dy = (event.changedTouches?.[0]?.clientY ?? start.y) - start.y;
		const ms = now() - start.at;
		start = null;
		dragging = false;
		if (wasDragging) letGo(dragOutcome({ dy, ms, height: el.offsetHeight }));
	};

	return {
		mount() {
			el.addEventListener("touchstart", onStart, { passive: true });
			el.addEventListener("touchmove", onMove, { passive: false });
			el.addEventListener("touchend", onEnd, { passive: true });
			el.addEventListener("touchcancel", onEnd, { passive: true });
		},
		destroy() {
			el.removeEventListener("touchstart", onStart);
			el.removeEventListener("touchmove", onMove);
			el.removeEventListener("touchend", onEnd);
			el.removeEventListener("touchcancel", onEnd);
		},
	};
}

export default {
	mounted() {
		this.drag = createSheetDrag({ el: this.el, win: window, doc: document });
		this.drag.mount();
	},
	destroyed() {
		this.drag.destroy();
	},
};
