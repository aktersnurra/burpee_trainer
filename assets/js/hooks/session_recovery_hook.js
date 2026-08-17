import { openSessionStore } from "./session_store.mjs";

const SessionRecoveryHook = {
  mounted() {
    this.clientSessionId = this.el.dataset.clientSessionId;
    this.sessionStatus = this.el.dataset.sessionStatus;
    this.store = null;
    this.recovery = this.recover();

    this.handleEvent("session_reported", (reply) =>
      this.acknowledgeReportedSession(reply),
    );
  },

  async recover() {
    if (!this.clientSessionId) return;

    try {
      const openStore = this.openSessionStore || openSessionStore;
      const store = await openStore();
      this.store = store;
      const draft = await store.loadDraftByClientSessionId(this.clientSessionId);

      if (!this.matchesClientSession(draft)) return;

      if (this.sessionStatus === "running") {
        const command = await store.loadLifecycleCommand(this.clientSessionId);
        if (!this.completedLifecycleCommand(command)) return;

        const reply = await this.pushEventReply("reconcile_local_completion", {
          client_session_id: this.clientSessionId,
        });
        if (reply?.status === "ok") this.prefillReport(draft);
      }

      if (this.sessionStatus === "report_pending") this.prefillReport(draft);
    } catch (_error) {
      // Leave the server-rendered resolver available when local recovery fails.
    }
  },

  matchesClientSession(draft) {
    return draft?.client_session_id === this.clientSessionId;
  },

  completedLifecycleCommand(command) {
    return (
      command?.client_session_id === this.clientSessionId &&
      command.kind === "mark_report_pending" &&
      command.payload?.client_session_id === this.clientSessionId
    );
  },

  pushEventReply(name, payload) {
    return new Promise((resolve) => {
      this.pushEvent(name, payload, resolve);
    });
  },

  prefillReport(draft) {
    const fields = [
      ["#session-resolution-count", draft.burpee_count_actual],
      ["#session-resolution-duration", draft.duration_sec_actual],
      ["#session-resolution-mood", draft.mood],
      ["#session-resolution-tags", Array.isArray(draft.tags) ? draft.tags.join(",") : draft.tags],
      ["#session-resolution-notes", draft.note_post],
    ];

    for (const [selector, value] of fields) {
      if (value === undefined || value === null) continue;
      const input = this.el.querySelector(selector);
      if (!input) continue;
      input.value = String(value);
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
    }
  },

  async acknowledgeReportedSession(reply) {
    if (!this.store || !Number.isInteger(reply?.session_id)) return;

    try {
      await this.store.markTraceReady(this.clientSessionId, reply.session_id);
      window.dispatchEvent(new CustomEvent("burpee:trace-upload-ready"));
      await this.store.deleteLifecycleCommand(this.clientSessionId);
      await this.store.deleteDraft(this.clientSessionId);
    } catch (_error) {
      // Retain recovery data if acknowledgement cleanup is incomplete.
    }
  },
};

export default SessionRecoveryHook;
