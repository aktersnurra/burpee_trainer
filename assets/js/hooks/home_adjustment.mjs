export default {
  mounted() {
    this.sync = () => {
      this.el.style.height = "auto";
      this.el.style.height = `${this.el.scrollHeight}px`;

      const form = this.el.closest?.("form");
      const action = form?.querySelector("#home-action");
      if (!action) return;

      const hasInstruction = this.el.value.trim().length > 0;
      const label = hasInstruction ? "Update" : "Start";
      form.dataset.hasInstruction = String(hasInstruction);
      action.setAttribute("aria-label", label);
      action.setAttribute("title", label);
    };
    this.el.addEventListener("input", this.sync);
    this.handleEvent?.("home_adjustment_reset", () => {
      this.el.value = "";
      this.sync();
    });
    this.sync();
  },
  destroyed() {
    this.el.removeEventListener("input", this.sync);
  },
};
