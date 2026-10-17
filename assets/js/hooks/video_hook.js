const VideoHook = {
	mounted() {
		const root = this.el.closest("[data-session-id]");
		this.sessionId = root?.dataset.sessionId || null;
		this.onPlay = () => {
			if (!this.sessionId) this.el.pause();
		};
		// Ending or finishing early both open the finish screen with how far it got.
		this.onEnded = () => {
			if (this.sessionId)
				this.pushEvent("video_ended", {
					watched_sec: Math.round(this.el.currentTime || 0),
				});
		};
		// Listened for on the page: LiveView replaces the button when Abort's question closes.
		this.root = root;
		this.onRootClick = (event) => {
			if (event.target?.closest?.("#video-finish-early")) this.onEnded();
		};

		this.el.addEventListener("play", this.onPlay);
		this.el.addEventListener("ended", this.onEnded);
		this.root?.addEventListener?.("click", this.onRootClick);
	},

	destroyed() {
		this.el.removeEventListener("play", this.onPlay);
		this.el.removeEventListener("ended", this.onEnded);
		this.root?.removeEventListener?.("click", this.onRootClick);
	},
};

export default VideoHook;
