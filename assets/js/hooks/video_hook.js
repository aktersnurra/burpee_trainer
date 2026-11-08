// A video session's player. The video plays once the server has a session; ending it, or a
// second tap on Finish early (the LiveView arms the first), opens the finish screen with how
// far it got. With the device's camera on, the camera counts reps while the video plays
// (`PoseTracker`, which needs no beat to count), and the end carries what it counted.
const VideoHook = {
	mounted() {
		const root = this.el.closest("[data-session-id]");
		this.root = root;
		this.sessionId = root?.dataset.sessionId || null;
		this.camera = root?.dataset.camera === "true";
		this.cameraStarted = false;
		this.cameraFailed = false;
		this.reps = 0;

		const tracker = () => root?.querySelector?.("#pose-tracker");
		const count = () => root?.querySelector?.("#video-camera-count");
		const command = (type) => tracker()?.dispatchEvent(new CustomEvent(type));

		this.onPlay = () => {
			if (!this.sessionId) {
				this.el.pause();
				return;
			}
			if (this.camera && !this.cameraStarted) {
				this.cameraStarted = true;
				command("pose-tracker:start");
			}
		};

		this.onEnded = () => {
			if (!this.sessionId) return;
			const payload = { watched_sec: Math.round(this.el.currentTime || 0) };
			if (this.cameraStarted && !this.cameraFailed) payload.counted_reps = this.reps;
			if (this.cameraStarted) command("pose-tracker:stop");
			this.pushEvent("video_ended", payload);
		};

		// Listened for on the page: LiveView replaces the button as it arms and lets go.
		this.onRootClick = (event) => {
			if (
				event.target?.closest?.("#video-finish-early") &&
				root?.dataset.armed === "finish"
			)
				this.onEnded();
		};

		this.onRep = () => {
			this.reps += 1;
			const el = count();
			if (el) el.textContent = String(this.reps);
		};

		// A camera that cannot start counts nothing and shows nothing; the athlete counts on
		// the finish screen.
		this.onStartFailed = () => {
			this.cameraFailed = true;
			const el = tracker();
			if (el) el.hidden = true;
		};

		this.el.addEventListener("play", this.onPlay);
		this.el.addEventListener("ended", this.onEnded);
		root?.addEventListener?.("click", this.onRootClick);
		root?.addEventListener?.("pose-tracker:rep", this.onRep);
		root?.addEventListener?.("pose-tracker:start-failed", this.onStartFailed);
	},

	destroyed() {
		this.el.removeEventListener("play", this.onPlay);
		this.el.removeEventListener("ended", this.onEnded);
		this.root?.removeEventListener?.("click", this.onRootClick);
		this.root?.removeEventListener?.("pose-tracker:rep", this.onRep);
		this.root?.removeEventListener?.("pose-tracker:start-failed", this.onStartFailed);
	},
};

export default VideoHook;
