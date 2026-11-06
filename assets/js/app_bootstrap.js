import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";
import ChatDock from "./hooks/chat_dock.mjs";
import HomeGestures from "./hooks/home_gestures.mjs";
import HoldRepeat from "./hooks/hold_repeat.mjs";
import { registerHomeChooserFeedback } from "./hooks/home_chooser_feedback.mjs";
import HomePendingSession from "./hooks/home_pending_session.mjs";
import HomeStartChoice from "./hooks/home_start_choice.mjs";
import { readStartChoices } from "./hooks/start_choices.mjs";
import SheetDrag from "./hooks/sheet_drag.mjs";
import SessionHook from "./hooks/session_hook";
import SessionCompleted from "./hooks/session_completed.mjs";
import VideoHook from "./hooks/video_hook";
import PoseDebug from "./hooks/pose_debug";
import PoseTraceButton from "./hooks/pose_trace_button";
import { startPoseTraceSync } from "./hooks/pose_trace_sync.mjs";
import { openSessionStore } from "./hooks/session_store.mjs";
import { viewTransitions } from "./view_transitions.mjs";
import { sessionCurtain } from "./session_curtain.mjs";

export function startApp(PoseTracker) {
	const csrfToken = document
		.querySelector("meta[name='csrf-token']")
		.getAttribute("content");
	const liveSocket = new LiveSocket("/live", Socket, {
		longPollFallbackMs: 2500,
		dom: viewTransitions(),
		// Read at every join, so a Home reached by live navigation renders the start choices as
		// the device remembers them now, not as they were when the page loaded.
		params: () => ({ _csrf_token: csrfToken, start_choices: readStartChoices() }),
		hooks: {
			ChatDock,
			HomeGestures,
			HoldRepeat,
			HomePendingSession,
			HomeStartChoice,
			SheetDrag,
			SessionHook,
			SessionCompleted,
			VideoHook,
			PoseTracker,
			PoseDebug,
			PoseTraceButton,
		},
	});

	startPoseTraceSync({
		documentRoot: document,
		windowRoot: window,
		openStore: openSessionStore,
		fetch: window.fetch.bind(window),
		csrfToken: () => document.querySelector("meta[name='csrf-token']").getAttribute("content"),
	});

	topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
	window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
	window.addEventListener("phx:page-loading-stop", (_info) => {
		topbar.hide();
	});

	registerHomeChooserFeedback();
	sessionCurtain();
	liveSocket.connect();
	window.liveSocket = liveSocket;

	if (process.env.NODE_ENV === "development") {
		window.addEventListener(
			"phx:live_reload:attached",
			({ detail: reloader }) => {
				reloader.enableServerLogs();
				let keyDown;
				window.addEventListener("keydown", (e) => (keyDown = e.key));
				window.addEventListener("keyup", (_e) => (keyDown = null));
				window.addEventListener(
					"click",
					(e) => {
						if (keyDown === "c") {
							e.preventDefault();
							e.stopImmediatePropagation();
							reloader.openEditorAtCaller(e.target);
						} else if (keyDown === "d") {
							e.preventDefault();
							e.stopImmediatePropagation();
							reloader.openEditorAtDef(e.target);
						}
					},
					true,
				);
				window.liveReloader = reloader;
			},
		);
	}
}
