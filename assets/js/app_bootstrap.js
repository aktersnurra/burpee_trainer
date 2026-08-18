import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";
import ChartHook from "./hooks/chart_hook";
import SessionHook from "./hooks/session_hook";
import SessionRecoveryHook from "./hooks/session_recovery_hook";
import VideoHook from "./hooks/video_hook";
import PoseDebug from "./hooks/pose_debug";
import PoseTraceButton from "./hooks/pose_trace_button";
import {
	canDrainPoseTraces,
	createPoseTraceUploader,
} from "./hooks/pose_trace_uploader.mjs";
import { openSessionStore } from "./hooks/session_store.mjs";

export function startApp(PoseTracker) {
	const themeStorage = {
		get() {
			try {
				return window.localStorage.getItem("phx:theme");
			} catch (_error) {
				return null;
			}
		},
		set(theme) {
			try {
				window.localStorage.setItem("phx:theme", theme);
			} catch (_error) {
				// Ignore unavailable storage so LiveView boot can continue.
			}
		},
		remove() {
			try {
				window.localStorage.removeItem("phx:theme");
			} catch (_error) {
				// Ignore unavailable storage so LiveView boot can continue.
			}
		},
	};

	const setTheme = (theme) => {
		if (theme === "system") {
			themeStorage.remove();
			document.documentElement.removeAttribute("data-theme");
		} else {
			themeStorage.set(theme);
			document.documentElement.setAttribute("data-theme", theme);
		}
	};

	if (!document.documentElement.hasAttribute("data-theme")) {
		setTheme(themeStorage.get() || "system");
	}

	window.addEventListener("storage", (event) => {
		if (event.key === "phx:theme") {
			setTheme(event.newValue || "system");
		}
	});

	window.addEventListener("phx:set-theme", (event) => {
		setTheme(event.target.dataset.phxTheme);
	});

	window.addEventListener("phx:toggle-theme", () => {
		const storedTheme = themeStorage.get();
		const currentTheme =
			storedTheme ||
			(window.matchMedia("(prefers-color-scheme: dark)").matches
				? "dark"
				: "light");
		setTheme(currentTheme === "dark" ? "light" : "dark");
	});

	const csrfToken = document
		.querySelector("meta[name='csrf-token']")
		.getAttribute("content");
	const liveSocket = new LiveSocket("/live", Socket, {
		longPollFallbackMs: 2500,
		params: { _csrf_token: csrfToken },
		hooks: {
			ChartHook,
			SessionHook,
			SessionRecoveryHook,
			VideoHook,
			PoseTracker,
			PoseDebug,
			PoseTraceButton,
		},
	});

	const traceUploaderReady = openSessionStore().then((store) =>
		createPoseTraceUploader({
			store,
			fetch: window.fetch.bind(window),
			csrfToken,
		}),
	);
	const drainPoseTraces = () => {
		if (!canDrainPoseTraces(document)) return;

		void traceUploaderReady
			.then((uploader) => uploader.drain())
			.catch(() => undefined);
	};

	window.addEventListener("online", drainPoseTraces);
	window.addEventListener("burpee:trace-upload-ready", drainPoseTraces);

	topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
	window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
	window.addEventListener("phx:page-loading-stop", (_info) => {
		topbar.hide();
		drainPoseTraces();
	});

	liveSocket.connect();
	drainPoseTraces();
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
