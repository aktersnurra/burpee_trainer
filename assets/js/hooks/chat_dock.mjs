// The box you write in, docked above the keyboard like the Claude app's.
//
// On iPhone the keyboard shrinks the *visual* viewport and leaves the layout viewport
// alone, so a bottom-fixed box ends up behind it. The dock measures the gap and lifts
// itself by it (`--keyboard-inset`), and tells the page how tall it is (`--chat-dock-height`)
// so the spacer under the conversation keeps the last line clear of it.

// Below this the viewport changed for the browser's own bars, not a keyboard.
export const KEYBOARD_MIN_PX = 80;

// How far up the keyboard (or anything else at the bottom) pushes the visual viewport.
export function keyboardInset({ innerHeight, viewport }) {
	if (!viewport) return 0;
	return Math.max(0, Math.round(innerHeight - viewport.height - viewport.offsetTop));
}

export function createChatDock({ el, win, doc }) {
	const root = doc.documentElement;
	const viewport = win.visualViewport;
	let version = el.dataset.version;
	let observer = null;

	const reducedMotion = () =>
		Boolean(win.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches);

	const sync = () => {
		const inset = keyboardInset({ innerHeight: win.innerHeight, viewport });
		root.style.setProperty("--keyboard-inset", `${inset}px`);
		root.style.setProperty("--chat-dock-height", `${el.offsetHeight}px`);
		el.dataset.keyboard = inset > KEYBOARD_MIN_PX ? "open" : "closed";
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
			viewport?.addEventListener("resize", sync);
			viewport?.addEventListener("scroll", sync);
			win.addEventListener("resize", sync);
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
			viewport?.removeEventListener("resize", sync);
			viewport?.removeEventListener("scroll", sync);
			win.removeEventListener("resize", sync);
			observer?.disconnect();
			root.style.removeProperty("--keyboard-inset");
			root.style.removeProperty("--chat-dock-height");
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
