import { cameraAvailable } from "./camera_available.mjs";
import { readStartChoices, writeStartChoice } from "./start_choices.mjs";

const NO_CAMERA = "No camera on this device";

// One of Home's start toggles (camera, warmup). The server renders it unpressed and
// ignores it after that; the device's remembered choice is the truth. On a device with
// no camera the camera toggle is off and disabled, and the remembered choice is kept.
const HomeStartChoice = {
  mounted() {
    const choice = this.el.dataset.startChoice;
    this.label = this.el.getAttribute("aria-label");
    this.showChoice(choice);

    this.onClick = () => {
      const next = this.el.getAttribute("aria-pressed") !== "true";
      this.el.setAttribute("aria-pressed", String(next));
      writeStartChoice(choice, next, this.storage);
    };
    this.el.addEventListener("click", this.onClick);

    if (choice === "camera") {
      this.checkCamera = () => {
        this.cameraChecked = cameraAvailable(this.mediaDevices).then((available) =>
          this.showCamera(available !== false),
        );
      };
      this.checkCamera();
      this.devices()?.addEventListener?.("devicechange", this.checkCamera);
    }
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick);
    if (this.checkCamera) {
      this.devices()?.removeEventListener?.("devicechange", this.checkCamera);
    }
  },

  devices() {
    if (this.mediaDevices !== undefined) return this.mediaDevices;
    try {
      return globalThis.navigator?.mediaDevices ?? null;
    } catch {
      return null;
    }
  },

  showChoice(choice) {
    const pressed = readStartChoices(this.storage)[choice] === true;
    this.el.setAttribute("aria-pressed", String(pressed));
  },

  showCamera(available) {
    this.el.disabled = !available;
    const label = available ? this.label : NO_CAMERA;
    this.el.setAttribute("aria-label", label);
    this.el.setAttribute("title", label);
    if (available) this.showChoice("camera");
    else this.el.setAttribute("aria-pressed", "false");
  },
};

export default HomeStartChoice;
