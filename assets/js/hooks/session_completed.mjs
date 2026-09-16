import { openSessionStore } from "./session_store.mjs";

// The server already holds this session's completion (for example, its save
// reply was lost before a reconnect). Settle retained local evidence the same
// way an acknowledged save does, then return Home.
const SessionCompleted = {
  mounted() {
    this.active = true;
    const { sessionId, contentHash, clientSessionId, redirectTo } =
      this.el.dataset;

    this.finalized = Promise.resolve()
      .then(() => (this.openStore || openSessionStore)())
      .then((store) =>
        store.finalizeServerCompletion(
          Number(sessionId),
          contentHash,
          clientSessionId,
        ),
      )
      .then(({ traceReady }) => {
        if (traceReady && this.active) this.announce("burpee:trace-upload-ready");
      })
      .catch(() => undefined)
      .then(() => {
        if (this.active) this.navigate(redirectTo);
      });
  },

  destroyed() {
    this.active = false;
  },

  announce(name) {
    window.dispatchEvent(new CustomEvent(name));
  },

  navigate(to) {
    window.location.assign(to);
  },
};

export default SessionCompleted;
