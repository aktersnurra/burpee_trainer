import { openSessionStore } from "./session_store.mjs";

const RESOLUTION_TAGS = [
  "tired",
  "great_energy",
  "bad_sleep",
  "sick",
  "travel",
  "hot",
];

const SessionRecoveryHook = {
  mounted() {
    this.clientSessionId = this.el.dataset.clientSessionId;
    this.sessionStatus = this.el.dataset.sessionStatus;
    this.store = null;
    this.touchedInputs = new WeakSet();
    this.reportForm = this.el.querySelector("#session-resolution-form");
    this.setTags(this.tagsInput()?.value);
    this.setMood(this.moodInput()?.value);
    this.trackManualReportChanges();
    this.handleTagClick = (event) => {
      const pill =
        event.target?.closest?.("[data-resolution-tag]") || event.target;
      const mood = pill?.dataset?.resolutionMood;
      if (mood !== undefined) {
        event.preventDefault();
        this.setMood(mood);
        return;
      }

      const tag = pill?.dataset?.resolutionTag;
      if (!tag) return;

      event.preventDefault();
      this.toggleTag(tag);
    };
    this.el.addEventListener("click", this.handleTagClick);
    this.storeReady = this.initializeStore();
    this.recovery = this.recover();

    this.reportForm?.addEventListener("submit", (event) => {
      event.preventDefault();
      event.stopPropagation();
      void this.submitReport();
    });
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleTagClick);
  },

  tagsInput() {
    return this.el.querySelector("#session-resolution-tags");
  },

  moodInput() {
    return this.el.querySelector("#session-resolution-mood");
  },

  moodButtons() {
    return this.el.querySelectorAll("[data-resolution-mood]");
  },

  tagPills() {
    return this.el.querySelectorAll("[data-resolution-tag]");
  },

  selectedTags() {
    return RESOLUTION_TAGS.filter((tag) =>
      [...this.tagPills()].some(
        (pill) =>
          pill.dataset.resolutionTag === tag &&
          pill.getAttribute("aria-pressed") === "true",
      ),
    );
  },

  toggleTag(tag) {
    const tags = this.selectedTags();
    this.setTags(
      tags.includes(tag)
        ? tags.filter((selected) => selected !== tag)
        : [...tags, tag],
    );
  },

  setTags(tags) {
    const requested = Array.isArray(tags)
      ? tags
      : typeof tags === "string"
        ? tags.split(",")
        : [];
    const selected = new Set(requested);
    const normalized = RESOLUTION_TAGS.filter((tag) => selected.has(tag));
    const input = this.tagsInput();

    if (input) {
      input.value = normalized.join(",");
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
    }

    for (const pill of this.tagPills()) {
      pill.setAttribute(
        "aria-pressed",
        normalized.includes(pill.dataset.resolutionTag) ? "true" : "false",
      );
    }

    return normalized;
  },

  setMood(value) {
    const mood = ["-1", "0", "1"].includes(String(value))
      ? String(value)
      : "";
    const input = this.moodInput();

    if (input) {
      input.value = mood;
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
    }

    for (const button of this.moodButtons()) {
      button.setAttribute(
        "aria-pressed",
        button.dataset.resolutionMood === mood ? "true" : "false",
      );
    }

    return mood;
  },

  async initializeStore() {
    try {
      const openStore = this.openSessionStore || openSessionStore;
      const store = await openStore();
      this.store = store;
      return store;
    } catch (_error) {
      // Reporting still succeeds when IndexedDB is unavailable.
      return null;
    }
  },

  async recover() {
    if (!this.clientSessionId) return;

    try {
      const store = await this.storeReady;
      if (!store) return;

      const draft = await store.loadDraftByClientSessionId(
        this.clientSessionId,
      );
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

  trackManualReportChanges() {
    for (const selector of this.reportFieldSelectors()) {
      const input = this.el.querySelector(selector);
      if (!input) continue;

      const markTouched = () => this.touchedInputs.add(input);
      input.addEventListener("input", markTouched);
      input.addEventListener("change", markTouched);
    }
  },

  reportFieldSelectors() {
    return [
      "#session-resolution-count",
      "#session-resolution-duration",
      "#session-resolution-mood",
      "#session-resolution-tags",
      "#session-resolution-notes",
    ];
  },

  prefillReport(draft) {
    const fields = [
      ["#session-resolution-count", draft.burpee_count_actual],
      ["#session-resolution-duration", draft.duration_sec_actual],
      ["#session-resolution-notes", draft.note_post],
    ];

    const moodInput = this.moodInput();
    if (
      draft.mood !== undefined &&
      draft.mood !== null &&
      this.canPrefill(moodInput)
    ) {
      this.setMood(draft.mood);
    }

    const tagsInput = this.tagsInput();
    if (
      draft.tags !== undefined &&
      draft.tags !== null &&
      this.canPrefill(tagsInput)
    ) {
      this.setTags(draft.tags);
    }

    for (const [selector, value] of fields) {
      if (value === undefined || value === null) continue;
      const input = this.el.querySelector(selector);
      if (!this.canPrefill(input)) continue;

      const replacedEstimate = input.dataset.estimated === "true";
      input.value = String(value);

      if (replacedEstimate) {
        delete input.dataset.estimated;
        const source = this.el.querySelector(`${selector}-source`);
        if (source) {
          source.textContent = "Recorded from this session.";
        }
      }

      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
    }
  },

  canPrefill(input) {
    return (
      input &&
      !input.disabled &&
      (input.value === "" || input.dataset.estimated === "true") &&
      !this.touchedInputs.has(input)
    );
  },

  reportAttributes() {
    const attrs = {};

    for (const input of this.reportForm?.elements || []) {
      const field = /^workout_session\[([^\]]+)\]$/.exec(input.name || "")?.[1];
      if (field) attrs[field] = input.value;
    }

    return attrs;
  },

  async submitReport() {
    if (this.reporting) return;
    this.reporting = true;

    try {
      const reply = await this.pushEventReply("report", {
        workout_session: this.reportAttributes(),
      });

      if (reply?.status !== "ok") return;

      const acknowledged = await this.acknowledgeReportedSession(reply);
      if (!acknowledged) return;

      this.navigateTo(reply.redirect_to);
    } catch (_error) {
      // The form remains available for a replay-safe retry.
    } finally {
      this.reporting = false;
    }
  },

  async acknowledgeReportedSession(reply) {
    if (
      !Number.isInteger(reply?.session_id) ||
      reply.client_session_id !== this.clientSessionId
    ) {
      return false;
    }

    const store = await this.storeReady;
    if (!store) return true;

    try {
      await store.markTraceReady(this.clientSessionId, reply.session_id);
      window.dispatchEvent(new CustomEvent("burpee:trace-upload-ready"));
      await store.deleteLifecycleCommand(this.clientSessionId);
      await store.deleteDraft(this.clientSessionId);
      return true;
    } catch (_error) {
      // Retain recovery data so a replayed report can retry this acknowledgement.
      return false;
    }
  },

  navigateTo(target) {
    if (typeof target !== "string" || !target.startsWith("/")) return;
    window.location.assign(target);
  },
};

export default SessionRecoveryHook;
