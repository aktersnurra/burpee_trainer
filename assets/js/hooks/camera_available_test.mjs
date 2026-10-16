import test from "node:test";
import assert from "node:assert/strict";
import { cameraAvailable } from "./camera_available.mjs";

const devices = (...kinds) => ({
  enumerateDevices: async () => kinds.map((kind) => ({ kind, deviceId: "", label: "" })),
});

test("a device that lists a video input has a camera", async () => {
  assert.equal(await cameraAvailable(devices("audioinput", "videoinput")), true);
});

test("a device that lists no video input has none", async () => {
  assert.equal(await cameraAvailable(devices("audioinput", "audiooutput")), false);
  assert.equal(await cameraAvailable(devices()), false);
});

test("a page with no media devices cannot use a camera", async () => {
  assert.equal(await cameraAvailable(null), false);
});

test("a browser that cannot say is given the benefit of the doubt", async () => {
  assert.equal(await cameraAvailable({}), null);
  assert.equal(
    await cameraAvailable({
      enumerateDevices: async () => {
        throw new Error("blocked");
      },
    }),
    null,
  );
  assert.equal(await cameraAvailable({ enumerateDevices: async () => "nonsense" }), null);
});
