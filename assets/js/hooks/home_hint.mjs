// The two swipes on Home are invisible, so Home says so: a line above the grab handle, for the
// first few visits or until the first swipe, whichever comes first. Kept per device; storage that
// is missing or refuses means the line shows each time, which is harmless.

const KEY = "burpee.hint.swipes";
export const MAX_VIEWS = 3;

function defaultStorage() {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

export function readHint(storage = defaultStorage()) {
  try {
    const parsed = JSON.parse(storage?.getItem(KEY) ?? "null");
    if (parsed && Number.isInteger(parsed.views)) return { views: parsed.views, swiped: parsed.swiped === true };
  } catch {
    // Fall through: nothing is known yet.
  }
  return { views: 0, swiped: false };
}

function write(hint, storage) {
  try {
    storage?.setItem(KEY, JSON.stringify(hint));
  } catch {
    // The hint shows again next time.
  }
}

export function shouldShowHint(hint) {
  return !hint.swiped && hint.views < MAX_VIEWS;
}

// Counts a visit and says whether this one shows the line.
export function noteView(storage = defaultStorage()) {
  const hint = readHint(storage);
  const show = shouldShowHint(hint);
  if (show) write({ ...hint, views: hint.views + 1 }, storage);
  return show;
}

export function noteSwipe(storage = defaultStorage()) {
  write({ ...readHint(storage), swiped: true }, storage);
}

export default {
  mounted() {
    if (noteView()) this.el.hidden = false;
  },
};
