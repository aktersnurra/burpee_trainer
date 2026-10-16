import { readStartChoices, writeStartChoice } from "./start_choices.mjs";

// One of Home's start toggles (camera, warmup). The server renders it unpressed and
// ignores it after that; the device's remembered choice is the truth.
const HomeStartChoice = {
  mounted() {
    const choice = this.el.dataset.startChoice;
    const pressed = readStartChoices(this.storage)[choice] === true;
    this.el.setAttribute("aria-pressed", String(pressed));

    this.onClick = () => {
      const next = this.el.getAttribute("aria-pressed") !== "true";
      this.el.setAttribute("aria-pressed", String(next));
      writeStartChoice(choice, next, this.storage);
    };
    this.el.addEventListener("click", this.onClick);
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick);
  },
};

export default HomeStartChoice;
