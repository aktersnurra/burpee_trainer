// A video session's player. The video plays once the server has a session; ending it, or a
// second tap on Finish early (the LiveView arms the first), opens the finish screen with how
// far it got.
//
// With the device's camera on, the camera starts as the page opens, its feed filling the
// screen (`#pose-tracker`, stage `setup`) until it finds you. A raised hand then plays the
// video, as the plan session's "Hand up" starts a workout; there is no timer, so the video
// never starts while you step back. The play chip starts it too, and is the way when the
// browser refuses to play without a tap. Playing, the feed shrinks to the video's corner
// (stage `live`) and counts reps (`PoseTracker`, which needs no beat to count); only reps from
// then on count, and the end carries them. A camera that cannot start (stage `failed`) offers
// Retry or Continue without camera (stage `off`), and then the video plays as without one.

// The plan session's hold for a raised hand, in sampled frames. Its own step name, so the
// tracker's camera-setup timer, which starts a plan workout on its own, never fires here.
const PLAY_STEP = "video_play";
const HOLD_FRAMES = 15;

const VideoHook = {
	mounted() {
		const root = this.el.closest("[data-session-id]");
		this.root = root;
		this.sessionId = root?.dataset.sessionId || null;
		this.camera = root?.dataset.camera === "true";
		this.stage = null;
		this.reps = 0;
		const defer = this.defer || ((fn) => setTimeout(fn, 0));

		const find = (id) => root?.querySelector?.(`#${id}`);
		const tracker = () => find("pose-tracker");
		const command = (type, detail) =>
			tracker()?.dispatchEvent(new CustomEvent(type, { detail }));
		const setText = (id, text) => {
			const el = find(id);
			if (el) el.textContent = text;
		};

		const setStage = (stage) => {
			this.stage = stage;
			const el = tracker();
			if (!el) return;
			el.dataset.stage = stage;
			// The pose is drawn over the feed while it fills the screen, as in the plan's setup.
			command("pose-tracker:preview-visibility", { visible: stage === "setup" });
			// Full screen, the setup is a dialog over the page; in the corner it is not.
			if (stage === "live" || stage === "off") {
				el.removeAttribute?.("role");
				el.removeAttribute?.("aria-modal");
			}
			el.hidden = stage === "off";
			const retry = find("video-camera-retry");
			if (retry) retry.hidden = stage !== "failed";
			const play = find("video-camera-play");
			if (play) play.hidden = stage === "failed";
		};

		const startCamera = () => {
			setStage("setup");
			setText("video-camera-status", "Starting camera");
			setText("video-camera-detail", this.videoName);
			command("pose-tracker:start");
		};

		// The browser may refuse to play without a tap; the play chip then asks for one.
		this.play = () => {
			const result = this.el.play?.();
			result?.catch?.(() => {
				if (this.stage !== "setup") return;
				setText("video-camera-status", "Tap play");
				setText("video-camera-detail", this.videoName);
				find("video-camera-play")?.setAttribute?.("data-attention", "");
			});
		};

		this.onPlay = () => {
			if (!this.sessionId) {
				this.el.pause();
				return;
			}
			if (this.stage === "setup") {
				// What the camera saw before the video is not part of the workout.
				command("pose-tracker:arm", { step: null, holdFramesRequired: 0 });
				command("pose-tracker:reset");
				this.reps = 0;
				setText("video-camera-count", "0");
				setStage("live");
			}
		};

		this.onEnded = () => {
			if (!this.sessionId) return;
			const payload = { watched_sec: Math.round(this.el.currentTime || 0) };
			if (this.stage === "live") payload.counted_reps = this.reps;
			if (this.stage === "live" || this.stage === "setup") command("pose-tracker:stop");
			this.pushEvent("video_ended", payload);
		};

		// Listened for on the page: LiveView replaces the button as it arms and lets go.
		this.onRootClick = (event) => {
			const target = event.target;
			if (target?.closest?.("#video-finish-early")) {
				if (root?.dataset.armed === "finish") this.onEnded();
			} else if (target?.closest?.("#video-camera-play")) this.play();
			else if (target?.closest?.("#video-camera-retry")) startCamera();
			else if (target?.closest?.("#video-camera-off")) {
				command("pose-tracker:stop");
				setStage("off");
			}
		};

		this.onRep = () => {
			if (this.stage !== "live") return;
			this.reps += 1;
			setText("video-camera-count", String(this.reps));
		};

		// Once the camera finds you, a raised hand plays; lost again, it waits.
		this.onReadiness = (event) => {
			if (this.stage !== "setup") return;
			const ready = ["ready", "optimal"].includes(event.detail?.state);
			setText("video-camera-status", ready ? "Hand up" : "Step into frame");
			setText("video-camera-detail", ready ? "or tap play" : this.videoName);
			command("pose-tracker:arm", {
				step: ready ? PLAY_STEP : null,
				holdFramesRequired: ready ? HOLD_FRAMES : 0,
			});
		};

		this.onStarted = () => {
			if (this.stage === "setup") setText("video-camera-status", "Step into frame");
		};

		this.onGesture = (event) => {
			if (this.stage === "setup" && event.detail?.step === PLAY_STEP) this.play();
		};

		this.onStartFailed = () => {
			if (this.stage !== "setup") return;
			setStage("failed");
			setText("video-camera-status", "Camera unavailable");
		};

		this.el.addEventListener("play", this.onPlay);
		this.el.addEventListener("ended", this.onEnded);
		root?.addEventListener?.("click", this.onRootClick);
		root?.addEventListener?.("pose-tracker:rep", this.onRep);
		root?.addEventListener?.("pose-tracker:readiness", this.onReadiness);
		root?.addEventListener?.("pose-tracker:started", this.onStarted);
		root?.addEventListener?.("pose-tracker:gesture-confirm", this.onGesture);
		root?.addEventListener?.("pose-tracker:start-failed", this.onStartFailed);

		if (this.camera && this.sessionId && tracker()) {
			this.videoName = find("video-camera-detail")?.textContent ?? "";
			this.stage = "setup";
			// After the tracker's hook has mounted, which holds a start until its code loads.
			defer(startCamera);
			// As the plan's setup: its status takes focus, so a screen reader starts there.
			find("video-camera-status")?.focus?.();
		}
	},

	destroyed() {
		this.el.removeEventListener("play", this.onPlay);
		this.el.removeEventListener("ended", this.onEnded);
		this.root?.removeEventListener?.("click", this.onRootClick);
		this.root?.removeEventListener?.("pose-tracker:rep", this.onRep);
		this.root?.removeEventListener?.("pose-tracker:readiness", this.onReadiness);
		this.root?.removeEventListener?.("pose-tracker:started", this.onStarted);
		this.root?.removeEventListener?.("pose-tracker:gesture-confirm", this.onGesture);
		this.root?.removeEventListener?.("pose-tracker:start-failed", this.onStartFailed);
	},
};

export default VideoHook;
