export default {
  mounted() {
    this.resize = () => {
      this.el.style.height = "auto";
      this.el.style.height = `${this.el.scrollHeight}px`;
    };
    this.el.addEventListener("input", this.resize);
    this.resize();
  },
  destroyed() {
    this.el.removeEventListener("input", this.resize);
  },
};
