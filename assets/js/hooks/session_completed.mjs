import { openSessionStore } from "./session_store.mjs";

// Do not leave retained evidence undiscoverable if local queue finalization fails.
const SessionCompleted = {
  mounted() {
    this.active = true;
    this.retryTimer = null;
    this.onRetry = () => { void this.finalize(); };
    this.el.addEventListener("click", this.onRetry);
    this.finalized = this.finalize();
  },

  finalize() {
    if (!this.active) return Promise.resolve();
    if (this.inFlight) return this.inFlight;
    if (this.retryTimer !== null) this.cancelRetry(this.retryTimer);
    this.retryTimer = null;
    const { sessionId, contentHash, clientSessionId, redirectTo } = this.el.dataset;
    this.el.textContent = "Session saved. Finishing local pose recovery…";
    this.inFlight = Promise.resolve()
      .then(() => (this.openStore || openSessionStore)())
      .then((store) => store.finalizeServerCompletion(Number(sessionId), contentHash, clientSessionId))
      .then(({ traceReady }) => {
        if (!this.active) return;
        if (traceReady) this.announce("burpee:trace-upload-ready");
        this.navigate(redirectTo);
      })
      .catch(() => {
        if (!this.active) return;
        this.el.textContent = "Session saved, but local pose recovery is pending. Stay here; retrying automatically. Tap to retry now.";
        this.retryTimer = this.scheduleRetry(() => {
          this.retryTimer = null;
          return this.finalize();
        });
      })
      .finally(() => { this.inFlight = null; });
    return this.inFlight;
  },

  destroyed() {
    this.active = false;
    if (this.retryTimer !== null) this.cancelRetry(this.retryTimer);
    this.el.removeEventListener("click", this.onRetry);
  },

  scheduleRetry(callback) { return setTimeout(callback, 5000); },
  cancelRetry(timer) { clearTimeout(timer); },
  announce(name) { window.dispatchEvent(new CustomEvent(name)); },
  navigate(to) { window.location.assign(to); },
};

export default SessionCompleted;
