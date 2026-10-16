// Whether this device has a camera: true, false, or null when the browser cannot say.
// Listing devices needs no permission; before it is granted the list still carries each
// device's kind. A page without media devices (not a secure context) can never use one.

function defaultMediaDevices() {
  try {
    return globalThis.navigator?.mediaDevices ?? null;
  } catch {
    return null;
  }
}

export async function cameraAvailable(mediaDevices = defaultMediaDevices()) {
  if (!mediaDevices) return false;
  if (typeof mediaDevices.enumerateDevices !== "function") return null;
  try {
    const devices = await mediaDevices.enumerateDevices();
    if (!Array.isArray(devices)) return null;
    return devices.some((device) => device?.kind === "videoinput");
  } catch {
    return null;
  }
}
