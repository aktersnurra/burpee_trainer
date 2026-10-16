const PoseTracker = {
	async mounted() {
		this.impl = null;
		// The session starts the camera as soon as it boots, which can be before the
		// tracker's code has loaded. Hold the last start or stop and replay it once loaded.
		let pending = null;
		const hold = (event) => {
			pending = event.type;
		};
		this.el.addEventListener("pose-tracker:start", hold);
		this.el.addEventListener("pose-tracker:stop", hold);

		const module = await (this.loadImpl || (() => import("./pose_tracker_impl.mjs")))();
		this.el.removeEventListener("pose-tracker:start", hold);
		this.el.removeEventListener("pose-tracker:stop", hold);
		if (!this.el.isConnected) return;
		this.impl = module.createPoseTracker(this);
		await this.impl.mounted();
		if (pending === "pose-tracker:start") {
			this.el.dispatchEvent(new CustomEvent("pose-tracker:start"));
		}
	},

	destroyed() {
		if (this.impl?.destroyed) this.impl.destroyed();
	},
};

export default PoseTracker;
