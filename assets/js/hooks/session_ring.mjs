const CX = 140;
const CY = 140;
const R = 107;
const CIRC = 2 * Math.PI * R;
const NS = "http://www.w3.org/2000/svg";

export const RING_INK_COLOR = "var(--session-ink)";
export const RING_TRACK_COLOR = "var(--session-ring-track)";

export function ringCircumference() {
	return CIRC;
}

export function ringDepletingOffset(progress) {
	const clampedProgress = Math.min(Math.max(progress, 0), 1);
	return CIRC * clampedProgress;
}

export function clearRing(svgEl) {
	while (svgEl.firstChild) svgEl.removeChild(svgEl.firstChild);
}

export function appendSessionRing(svgEl) {
	clearRing(svgEl);
	appendCircle(svgEl, RING_TRACK_COLOR);
	const progressRing = appendCircle(svgEl, RING_INK_COLOR);
	progressRing.setAttribute("stroke-dasharray", CIRC.toFixed(4));
	progressRing.setAttribute("stroke-dashoffset", "0");
	return progressRing;
}

export function updateSessionRing(progressRing, progress) {
	progressRing.setAttribute("stroke", RING_INK_COLOR);
	progressRing.setAttribute("stroke-dasharray", CIRC.toFixed(4));
	progressRing.setAttribute(
		"stroke-dashoffset",
		ringDepletingOffset(progress).toFixed(4),
	);
}

function appendCircle(svgEl, stroke) {
	const circle = document.createElementNS(NS, "circle");
	circle.setAttribute("cx", CX);
	circle.setAttribute("cy", CY);
	circle.setAttribute("r", R);
	circle.setAttribute("fill", "none");
	circle.setAttribute("stroke", stroke);
	circle.setAttribute("stroke-width", "18");
	circle.setAttribute("stroke-linecap", "butt");
	circle.setAttribute("transform", `rotate(-90 ${CX} ${CY})`);
	svgEl.appendChild(circle);
	return circle;
}
