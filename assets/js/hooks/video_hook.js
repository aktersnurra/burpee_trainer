const VideoHook = {
  mounted() {
    this.clientSessionId = crypto.randomUUID();
    this.started = false;
    this.ended = false;
    this.pendingReport = false;
    this.startButton = document.getElementById("video-start-workout");
    this.status = document.getElementById("video-lifecycle-status");
    this.error = document.getElementById("video-lifecycle-error");
    this.resolverLink = document.getElementById("video-resolve-session");
    this.retryButton = document.getElementById("video-report-retry");

    this.el.addEventListener("play", () => {
      if (!this.started) {
        this.el.pause();
        this.showStatus("Start the workout before playing the video.");
      }
    });
    this.el.addEventListener("ended", () => this.reportPending());
    this.startButton?.addEventListener("click", () => this.begin());
    this.retryButton?.addEventListener("click", () => this.reportPending());
  },

  begin() {
    if (this.started) return;
    this.startButton.disabled = true;
    this.clearError();
    this.showStatus("Starting workout…");

    this.pushEvent(
      "begin_video_session",
      { client_session_id: this.clientSessionId },
      (reply) => {
        if (reply.status === "ok") {
          this.started = true;
          this.showStatus("Workout started. Video playback is enabled.");
          void this.el
            .play()
            .catch(() =>
              this.showStatus(
                "Workout started. Press play when you are ready.",
              ),
            );
        } else {
          this.startButton.disabled = false;
          this.showError(reply);
        }
      },
    );
  },

  reportPending() {
    if (!this.started || this.pendingReport) return;
    this.ended = true;
    this.pendingReport = true;
    this.retryButton.hidden = true;
    this.clearError();
    this.showStatus("Preparing your workout report…");

    this.pushEvent(
      "mark_video_report_pending",
      { client_session_id: this.clientSessionId },
      (reply) => {
        this.pendingReport = false;
        if (reply.status === "ok") {
          this.showStatus("Workout complete. Your report is ready below.");
        } else {
          this.retryButton.hidden = false;
          this.showError(reply);
        }
      },
    );
  },

  showStatus(message) {
    if (this.status) this.status.textContent = message;
  },

  clearError() {
    if (this.error) {
      this.error.hidden = true;
      this.error.textContent = "";
    }
    if (this.resolverLink) this.resolverLink.hidden = true;
  },

  showError(reply) {
    if (this.error) {
      this.error.hidden = false;
      this.error.textContent =
        reply.message || "Could not update workout lifecycle. Try again.";
    }
    if (reply.resolve_to && this.resolverLink) {
      this.resolverLink.href = reply.resolve_to;
      this.resolverLink.hidden = false;
    }
  },
};

export default VideoHook;
