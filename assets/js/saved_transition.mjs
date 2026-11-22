// Saving a session leaves it by a full page load (SessionCompleted), which the patch transitions
// cannot see. The CSS opts same-site page loads into a cross-document view transition
// (@view-transition, off under reduced motion) and draws the save's from Home's arrival; this
// lets only the save's page load run one. Every other page load skips it.
export const LEAVING_SAVED = "burpee:leaving-saved";

export function savedTransition(win = window) {
	let leavingSaved = false;
	win.addEventListener(LEAVING_SAVED, () => (leavingSaved = true));
	win.addEventListener("pageswap", (event) => {
		const transition = event.viewTransition;
		const saved = leavingSaved;
		leavingSaved = false;
		if (transition && !saved) transition.skipTransition();
	});
}
