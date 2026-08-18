import { createPoseTracker } from "./pose_tracker_impl.mjs";

const PoseTrackerFixture = {
	async mounted() {
		this.impl = createPoseTracker(this, {
			controlledPoseFixture: globalThis.__burpeePoseFixture,
		});
		await this.impl.mounted();
	},

	destroyed() {
		if (this.impl?.destroyed) this.impl.destroyed();
	},
};

export default PoseTrackerFixture;
