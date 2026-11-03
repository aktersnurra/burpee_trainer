// A tap on an element marked data-vt asks for the page update it causes to move, through the
// browser's View Transitions API: "forward" and "back" slide sideways, "rise" brings the next
// view up from the bottom like a sheet, "drop" sends the view away downward, and "attach" lets
// the rest settle in place. The direction lives on <html data-vt> while the transition runs;
// the CSS draws the move.
//
// With data-vt-from (a selector, looked up inside the tapped element first, then the page), the
// workout's name travels: what it names before the update and Home's title after it share one
// view-transition-name, so the name flies from the row or proposal into Home's title.
//
// "attach" holds the drawer where it is (`<html data-vt-hold>`) from the tap until the update
// arrives: the tap hides it at once, and the move must start from the list as it was.
//
// Without the API, with reduced motion, or when no update follows the tap within a second, the
// page simply updates.
const PENDING_MS = 1000;
export const TITLE_NAME = "workout-title";
export const HOME_TITLE = "#home-summary .home-workout-name";

export function viewTransitions(doc = document, win = window) {
  let pending = null;
  const root = doc.documentElement;
  const release = () => delete root.dataset.vtHold;
  const canMove = () =>
    typeof doc.startViewTransition === "function" &&
    !win.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

  doc.addEventListener(
    "click",
    (event) => {
      const el = event.target?.closest?.("[data-vt]");
      if (!el) return;
      pending = { direction: el.dataset.vt, from: el.dataset.vtFrom, el, at: Date.now() };
      if (pending.direction === "attach" && canMove()) {
        root.dataset.vtHold = "";
        win.setTimeout?.(release, PENDING_MS);
      }
    },
    true,
  );

  const find = (el, selector) =>
    (selector && (el?.querySelector?.(selector) || doc.querySelector(selector))) || null;

  return {
    onDocumentPatch(start) {
      const tap = pending && Date.now() - pending.at < PENDING_MS ? pending : null;
      pending = null;
      if (!tap || !canMove()) {
        release();
        return start();
      }

      root.dataset.vt = tap.direction;
      const from = find(tap.el, tap.from);
      let to = null;
      if (from) from.style.viewTransitionName = TITLE_NAME;

      const transition = doc.startViewTransition(() => {
        if (from) from.style.viewTransitionName = "";
        release();
        start();
        if (from) {
          to = doc.querySelector(HOME_TITLE);
          if (to) to.style.viewTransitionName = TITLE_NAME;
        }
      });
      transition.finished.finally(() => {
        delete root.dataset.vt;
        if (to) to.style.viewTransitionName = "";
      });
    },
  };
}
