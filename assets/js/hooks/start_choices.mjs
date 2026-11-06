// How a workout starts on this device: with the camera, with the warmup. Kept per device
// because the camera depends on where the phone is, in cookies so the server renders Home's
// toggles as they are (`BurpeeTrainerWeb.StartChoices`). Cookies that are missing or refused
// fall back to the defaults; they never stop a workout.

const DEFAULTS = { camera: false, warmup: true };
const COOKIES = { camera: "burpee_start_camera", warmup: "burpee_start_warmup" };
const ONE_YEAR = 60 * 60 * 24 * 365;

function defaultJar() {
  try {
    return globalThis.document;
  } catch {
    return undefined;
  }
}

function cookies(jar) {
  try {
    return Object.fromEntries(
      String(jar?.cookie ?? "")
        .split(";")
        .map((pair) => pair.trim().split("=")),
    );
  } catch {
    return {};
  }
}

function read(values, choice) {
  const value = values[COOKIES[choice]];
  if (value === "1") return true;
  if (value === "0") return false;
  return DEFAULTS[choice];
}

export function readStartChoices(jar = defaultJar()) {
  const values = cookies(jar);
  return { camera: read(values, "camera"), warmup: read(values, "warmup") };
}

export function writeStartChoice(choice, value, jar = defaultJar()) {
  if (!(choice in COOKIES)) return;
  try {
    jar.cookie = `${COOKIES[choice]}=${value ? "1" : "0"}; path=/; max-age=${ONE_YEAR}; samesite=lax`;
  } catch {
    // The choice lasts for this page only.
  }
}
