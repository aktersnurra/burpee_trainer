// The way into the runner: the Play pill is ink, the runner's ground, so a tap grows an ink
// curtain from the pill's box to the whole screen and the camera setup or count-in appears on
// it. Leaving a night screen (camera setup or the runner) by live navigation runs it the other
// way: the screen goes ink and the ink shrinks back into Home's Play pill.
//
// Play reaches the session by live navigation to another LiveView, which the page-patch view
// transitions cannot capture; the curtain lives on <body>, outside the replaced main view.
// With reduced motion, or when no navigation follows the tap, the page simply updates.
const PLAY = ".home-play-action";
const NIGHT = ".session-night";
const NAVIGATION_WAIT_MS = 1500;
const STUCK_MS = 5000;
const FADE_MS = 160;

export function sessionCurtain(doc = document, win = window) {
	let curtain = null;
	let leavingNight = false;
	let timer = null;
	let grown = Promise.resolve();

	const reduced = () => win.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
	const settle = () => {
		const style = win.getComputedStyle?.(doc.documentElement);
		const ms = Number.parseFloat(style?.getPropertyValue("--motion-settle"));
		return {
			duration: Number.isFinite(ms) ? ms : 360,
			easing: style?.getPropertyValue("--ease-out")?.trim() || "ease-out",
		};
	};
	const boxOf = (el) => {
		const rect = el.getBoundingClientRect();
		const radius = win.getComputedStyle?.(el)?.borderRadius || "0px";
		return `inset(${rect.top}px ${win.innerWidth - rect.right}px ${win.innerHeight - rect.bottom}px ${rect.left}px round ${radius})`;
	};
	const FULL = "inset(0px 0px 0px 0px round 0px)";

	const clear = () => {
		win.clearTimeout(timer);
		timer = null;
		curtain?.remove();
		curtain = null;
	};
	const fadeAway = () => {
		const el = curtain;
		curtain = null;
		win.clearTimeout(timer);
		if (!el) return;
		el.animate([{ opacity: 1 }, { opacity: 0 }], { duration: FADE_MS }).finished.finally(() => el.remove());
	};
	const cover = (clipPath) => {
		clear();
		curtain = doc.createElement("div");
		curtain.className = "session-curtain";
		curtain.setAttribute("aria-hidden", "true");
		curtain.style.clipPath = clipPath;
		doc.body.appendChild(curtain);
		return curtain;
	};

	doc.addEventListener(
		"click",
		(event) => {
			const play = event.target?.closest?.(PLAY);
			if (!play || play.disabled || reduced()) return;
			const el = cover(boxOf(play));
			el.style.clipPath = FULL;
			grown = el.animate([{ clipPath: boxOf(play) }, { clipPath: FULL }], settle()).finished.catch(() => {});
			// A tap that leads nowhere (a refused start) lets go of the screen.
			timer = win.setTimeout(fadeAway, NAVIGATION_WAIT_MS);
		},
		true,
	);

	win.addEventListener("phx:page-loading-start", (event) => {
		if (curtain) {
			win.clearTimeout(timer);
			timer = win.setTimeout(clear, STUCK_MS);
			return;
		}
		leavingNight = event.detail?.kind === "redirect" && !reduced() && Boolean(doc.querySelector(NIGHT));
		if (leavingNight) {
			cover(FULL);
			timer = win.setTimeout(clear, STUCK_MS);
		}
	});

	win.addEventListener("phx:page-loading-stop", () => {
		if (!curtain) return;
		if (leavingNight) {
			leavingNight = false;
			const el = curtain;
			curtain = null;
			win.clearTimeout(timer);
			// LiveView reports the load done (more than once) just before it puts the new view in
			// place, so Play is looked up on the next frame.
			win.requestAnimationFrame(() => {
				const play = doc.querySelector(PLAY);
				if (!play) {
					el.animate([{ opacity: 1 }, { opacity: 0 }], { duration: FADE_MS }).finished.finally(() => el.remove());
					return;
				}
				el.style.clipPath = boxOf(play);
				el.animate([{ clipPath: FULL }, { clipPath: boxOf(play) }], settle()).finished.finally(() => el.remove());
			});
			return;
		}
		// Into the runner, once the pill has grown: its ground is the curtain's ink, so the curtain
		// just goes (a light screen, the completion review of a draft, fades in).
		const el = curtain;
		grown.then(() => {
			if (curtain !== el) return;
			if (doc.querySelector(NIGHT)) clear();
			else fadeAway();
		});
	});
}
