// A tap on an element marked data-vt="forward" or data-vt="back" asks for the page update
// it causes to slide that way, through the browser's View Transitions API. The direction
// lives on <html data-vt> while the transition runs; the CSS draws the slide. Without the
// API, with reduced motion, or when no update follows the tap within a second, the page
// simply updates.
const PENDING_MS = 1000;

export function viewTransitions(doc = document, win = window) {
  let pending = null;

  doc.addEventListener(
    "click",
    (event) => {
      const el = event.target?.closest?.("[data-vt]");
      if (el) pending = { direction: el.dataset.vt, at: Date.now() };
    },
    true,
  );

  return {
    onDocumentPatch(start) {
      const direction = pending && Date.now() - pending.at < PENDING_MS ? pending.direction : null;
      pending = null;
      const reduced = win.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
      if (!direction || reduced || typeof doc.startViewTransition !== "function") return start();

      const root = doc.documentElement;
      root.dataset.vt = direction;
      doc.startViewTransition(start).finished.finally(() => delete root.dataset.vt);
    },
  };
}
