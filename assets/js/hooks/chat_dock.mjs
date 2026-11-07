// The box you write in, docked above the keyboard like the Claude app's.
//
// On iPhone the keyboard shrinks the *visual* viewport and leaves the layout viewport
// alone, so a bottom-fixed box ends up behind it. The dock measures the gap and lifts
// itself by it (`--keyboard-inset`), and tells the page how tall it is (`--chat-dock-height`)
// so the spacer under the conversation keeps the last line clear of it.
//
// A screen with a dock scrolls inside itself, `--viewport-height` tall: what the keyboard
// leaves. Were the page itself to scroll, iOS would slide it under the keyboard as you
// scroll, and the box would trail behind until the next measure. The page stays at the top.
//
// With a mouse and keyboard, Enter sends and Shift+Enter starts a new line, as in the Claude
// app; on a touch screen the return key keeps its new line, and the arrow sends.

// Below this the viewport changed for the browser's own bars, not a keyboard.
export const KEYBOARD_MIN_PX = 80;

// How far up the keyboard (or anything else at the bottom) pushes the visual viewport.
// `edge` is where the dock's bottom sits with no lift: the layout viewport's bottom, which
// `innerHeight` only approximates on iPhone while Safari's own bars come and go.
export function keyboardInset({ innerHeight, edge = innerHeight, viewport }) {
	if (!viewport) return 0;
	return Math.max(0, Math.round(edge - viewport.height - viewport.offsetTop));
}

export function createChatDock({ el, win, doc }) {
	const root = doc.documentElement;
	const viewport = win.visualViewport;
	let version = el.dataset.version;
	let observer = null;
	let applied = 0;

	const reducedMotion = () =>
		Boolean(win.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches);
	const finePointer = () =>
		Boolean(win.matchMedia?.("(hover: hover) and (pointer: fine)")?.matches);

	const sendOnEnter = (event) => {
		if (event.key !== "Enter" || event.shiftKey || event.altKey || event.ctrlKey || event.metaKey)
			return;
		// An input method composing a word uses Enter to accept it.
		if (event.isComposing || !finePointer()) return;
		const field = event.target;
		if (field?.tagName !== "TEXTAREA" || !field.form) return;
		event.preventDefault();
		if (field.value.trim() !== "") field.form.requestSubmit();
	};

	// iOS slides the page up to reveal a focused field; put it back, unless the owner zoomed in
	// and pans on purpose.
	const pin = () => {
		const zoomed = (viewport?.scale ?? 1) > 1.01;
		if (!zoomed && ((viewport?.offsetTop ?? 0) > 0 || win.scrollY > 0)) win.scrollTo(0, 0);
	};

	const sync = () => {
		pin();
		const height = viewport ? viewport.height * (viewport.scale ?? 1) : win.innerHeight;
		root.style.setProperty("--viewport-height", `${Math.round(height)}px`);
		// Measure the dock's own resting edge, so the box lands on the keyboard whatever the
		// browser's bars are doing; take back the lift it already carries.
		const rect = el.getBoundingClientRect?.();
		const edge = rect && rect.bottom > 0 ? rect.bottom + applied : win.innerHeight;
		const inset = keyboardInset({ innerHeight: win.innerHeight, edge, viewport });
		applied = inset;
		root.style.setProperty("--keyboard-inset", `${inset}px`);
		// The home indicator hides behind the keyboard; CSS reads this to drop its padding.
		root.style.setProperty("--keyboard-open", inset > KEYBOARD_MIN_PX ? "1" : "0");
		root.style.setProperty("--chat-dock-height", `${el.offsetHeight}px`);
		el.dataset.keyboard = inset > KEYBOARD_MIN_PX ? "open" : "closed";
	};

	// iOS reports the keyboard late and in pieces while it slides, so a focus change measures again
	// once it has settled, not only when the first resize arrives.
	const settleLater = () => {
		sync();
		win.setTimeout?.(sync, 350);
	};

	// The newest thing said comes to the top of the screen, with its answer below it.
	const bringIntoView = () => {
		const target = el.dataset.scrollTo && doc.querySelector(el.dataset.scrollTo);
		target?.scrollIntoView({
			behavior: reducedMotion() ? "auto" : "smooth",
			block: "start",
		});
	};

	return {
		mount() {
			el.addEventListener?.("keydown", sendOnEnter);
			viewport?.addEventListener("resize", sync);
			viewport?.addEventListener("scroll", sync);
			win.addEventListener("resize", sync);
			doc.addEventListener?.("focusin", settleLater);
			doc.addEventListener?.("focusout", settleLater);
			if (win.ResizeObserver) {
				observer = new win.ResizeObserver(sync);
				observer.observe(el);
			}
			sync();
			if (el.dataset.scrollOnMount !== "false") bringIntoView();
		},
		update() {
			sync();
			if (el.dataset.version !== version) {
				version = el.dataset.version;
				bringIntoView();
			}
		},
		destroy() {
			el.removeEventListener?.("keydown", sendOnEnter);
			viewport?.removeEventListener("resize", sync);
			viewport?.removeEventListener("scroll", sync);
			win.removeEventListener("resize", sync);
			doc.removeEventListener?.("focusin", settleLater);
			doc.removeEventListener?.("focusout", settleLater);
			observer?.disconnect();
			root.style.removeProperty("--keyboard-inset");
			root.style.removeProperty("--keyboard-open");
			root.style.removeProperty("--chat-dock-height");
			root.style.removeProperty("--viewport-height");
		},
	};
}

export default {
	mounted() {
		this.dock = createChatDock({ el: this.el, win: window, doc: document });
		this.dock.mount();
	},
	updated() {
		this.dock.update();
	},
	destroyed() {
		this.dock.destroy();
	},
};
