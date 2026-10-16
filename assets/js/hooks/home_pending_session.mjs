import { openSessionStore } from "./session_store.mjs";

const HomePendingSession = {
  mounted() {
    this.readGeneration = 0;
    this.checkDraft();
  },

  updated() {
    this.checkDraft();
  },

  destroyed() {
    this.readGeneration += 1;
  },

  checkDraft() {
    const generation = ++this.readGeneration;
    const sessionId = Number(this.el.dataset.sessionId);
    const contentHash = this.el.dataset.contentHash;
    this.pendingRead = Promise.resolve()
      .then(() => (this.openStore || openSessionStore)())
      .then((store) => store.loadDraft({ sessionId, contentHash }))
      .then((draft) => {
        if (this.readGeneration !== generation) return;
        this.el.querySelector("#home-session-state").textContent = draft
          ? "Session ready to log"
          : "In progress";
        this.el.querySelector("#home-resume-action-label").textContent = draft
          ? "Review & save"
          : "Resume";
      })
      .catch(() => undefined);
  },
};

export default HomePendingSession;
