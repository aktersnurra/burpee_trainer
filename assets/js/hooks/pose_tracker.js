const PoseTracker = {
	async mounted() {
		this.impl = null;
		const module = await import("./pose_tracker_impl.mjs");
		if (!this.el.isConnected) return;
		this.impl = module.createPoseTracker(this);
		await this.impl.mounted();
	},

	destroyed() {
		if (this.impl?.destroyed) this.impl.destroyed();
	},
};

export default PoseTracker;
