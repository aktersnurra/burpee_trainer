// One finger, one deliberate stroke: right, left, up or down. Everything else is a tap or a
// scroll and is left alone.

export const SWIPE_MIN_PX = 56;
export const SWIPE_MAX_MS = 800;
// A stroke counts for its main direction only when it is clearly more that than the other.
export const SWIPE_DOMINANCE = 1.6;

export function classifySwipe({ dx, dy, ms }) {
	if (ms > SWIPE_MAX_MS) return null;
	const ax = Math.abs(dx);
	const ay = Math.abs(dy);
	if (ax >= SWIPE_MIN_PX && ax >= ay * SWIPE_DOMINANCE) return dx > 0 ? "right" : "left";
	if (ay >= SWIPE_MIN_PX && ay >= ax * SWIPE_DOMINANCE) return dy > 0 ? "down" : "up";
	return null;
}

// Whether the page cannot scroll further down, so an upward stroke is not a scroll.
export function atPageBottom({ scrollTop, innerHeight, scrollHeight }) {
	return scrollTop + innerHeight >= scrollHeight - 2;
}

// Calls `onSwipe(direction, event)` for each swipe that starts inside `el`, except those
// that start in an element matching `ignore` (a drawer's list, a field) and upward strokes
// while the page can still scroll down.
export function createSwipeTracker({ el, win, doc, onSwipe, ignore = null, now = Date.now }) {
	let start = null;

	const onStart = (event) => {
		if (event.touches.length !== 1) {
			start = null;
			return;
		}
		if (ignore && event.target?.closest?.(ignore)) {
			start = null;
			return;
		}
		const touch = event.touches[0];
		start = { x: touch.clientX, y: touch.clientY, at: now() };
	};

	const onEnd = (event) => {
		if (!start) return;
		const touch = event.changedTouches[0];
		const direction = classifySwipe({
			dx: touch.clientX - start.x,
			dy: touch.clientY - start.y,
			ms: now() - start.at,
		});
		start = null;
		if (!direction) return;
		if (direction === "up") {
			const root = doc.scrollingElement || doc.documentElement;
			const bottom = atPageBottom({
				scrollTop: root.scrollTop,
				innerHeight: win.innerHeight,
				scrollHeight: root.scrollHeight,
			});
			if (!bottom) return;
		}
		onSwipe(direction, event);
	};

	const onCancel = () => {
		start = null;
	};

	return {
		mount() {
			el.addEventListener("touchstart", onStart, { passive: true });
			el.addEventListener("touchend", onEnd, { passive: true });
			el.addEventListener("touchcancel", onCancel, { passive: true });
		},
		destroy() {
			el.removeEventListener("touchstart", onStart);
			el.removeEventListener("touchend", onEnd);
			el.removeEventListener("touchcancel", onCancel);
		},
	};
}
