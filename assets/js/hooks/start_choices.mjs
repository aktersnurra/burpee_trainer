// How a workout starts on this device: with the camera, with the warmup. Kept per device
// because the camera depends on where the phone is. Storage that is missing or refuses
// falls back to the defaults; it never stops a workout.

const DEFAULTS = { camera: false, warmup: true };
const KEYS = { camera: "burpee.start.camera", warmup: "burpee.start.warmup" };

function defaultStorage() {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

function read(storage, choice) {
  try {
    const value = storage?.getItem(KEYS[choice]);
    if (value === "1") return true;
    if (value === "0") return false;
  } catch {
    // Fall through to the default.
  }
  return DEFAULTS[choice];
}

export function readStartChoices(storage = defaultStorage()) {
  return { camera: read(storage, "camera"), warmup: read(storage, "warmup") };
}

export function writeStartChoice(choice, value, storage = defaultStorage()) {
  if (!(choice in KEYS)) return;
  try {
    storage?.setItem(KEYS[choice], value ? "1" : "0");
  } catch {
    // The choice lasts for this page only.
  }
}
