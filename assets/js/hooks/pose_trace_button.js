const TRACE_EVENT = "pose-debug:start-trace";

const PoseTraceButton = {
	mounted() {
		this.started = false;
		this.start = this.start.bind(this);
		this.el.addEventListener("pointerup", this.start);
		this.el.addEventListener("touchend", this.start, { passive: false });
		this.el.addEventListener("click", this.start);
	},

	destroyed() {
		this.el.removeEventListener("pointerup", this.start);
		this.el.removeEventListener("touchend", this.start);
		this.el.removeEventListener("click", this.start);
	},

	start(event) {
		event.preventDefault();
		event.stopPropagation();

		if (this.started) return;
		this.started = true;
		window.setTimeout(() => {
			this.started = false;
		}, 500);

		this.el.textContent = "Trace tap received";
		document
			.querySelector("#pose-debug")
			?.dispatchEvent(new CustomEvent(TRACE_EVENT, { bubbles: true }));
	},
};

export default PoseTraceButton;
