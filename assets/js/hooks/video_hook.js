const VideoHook = {
	mounted() {
		this.sessionId =
			this.el.closest("[data-session-id]")?.dataset.sessionId || null;
		this.onPlay = () => {
			if (!this.sessionId) this.el.pause();
		};
		this.onEnded = () => {
			if (this.sessionId) this.pushEvent("video_ended", {});
		};

		this.el.addEventListener("play", this.onPlay);
		this.el.addEventListener("ended", this.onEnded);
	},

	destroyed() {
		this.el.removeEventListener("play", this.onPlay);
		this.el.removeEventListener("ended", this.onEnded);
	},
};

export default VideoHook;
