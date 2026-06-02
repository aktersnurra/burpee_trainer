import { createBlazePoseDetector } from "./blazepose_detector.mjs";
import { initialCounterState, countRep } from "./pose_rep_counter.mjs";
import { sampleFromPose } from "./pose_signal.mjs";
import { buildFinishPayload } from "./pose_trace.mjs";

export function createPoseTracker(hook) {
	let stream = null;
	let detector = null;
	let video = null;
	let raf = null;
	let state = initialCounterState();
	let startedAt = null;
	let trackingState = "lost";
	let mounted = true;

	async function mountedHook() {
		hook.el.addEventListener("pose-tracker:finish", finish);

		try {
			stream = await navigator.mediaDevices.getUserMedia({
				video: { facingMode: "user" },
				audio: false,
			});

			video = document.createElement("video");
			video.muted = true;
			video.playsInline = true;
			video.srcObject = stream;
			await video.play();

			detector = await createBlazePoseDetector();

			if (!mounted) return;
			startedAt = performance.now();
			hook.pushEvent("tracker_ready", {});
			loop();
		} catch (error) {
			console.error("PoseTracker failed", error);
			hook.pushEvent("track", {
				state: "lost",
				reason: error?.message || error?.name || "tracker_error",
			});
		}
	}

	async function loop() {
		if (!mounted || !detector || !video || startedAt == null) return;

		const poses = await detector.estimatePoses(video);
		const sample = sampleFromPose(
			poses[0],
			performance.now() - startedAt,
			video,
		);

		if (sample.confidence < 0.5 && trackingState !== "lost") {
			trackingState = "lost";
			hook.pushEvent("track", { state: "lost" });
		}

		if (sample.confidence >= 0.5 && trackingState !== "live") {
			trackingState = "live";
			hook.pushEvent("track", { state: "live" });
		}

		const result = countRep(state, sample);
		state = result.state;

		if (result.rep) {
			hook.pushEvent("rep", {
				index: state.cadenceMs.length,
				t_ms: sample.tMs,
			});
		}

		raf = requestAnimationFrame(loop);
	}

	function finish(event) {
		const durationMs = event.detail?.durationMs;
		try {
			hook.pushEvent(
				"finish",
				buildFinishPayload({ durationMs, cadenceMs: state.cadenceMs }),
			);
		} catch (_error) {
			hook.pushEvent("track", { state: "lost", reason: "invalid_finish" });
		}
	}

	function destroyed() {
		mounted = false;
		hook.el.removeEventListener("pose-tracker:finish", finish);
		if (raf) cancelAnimationFrame(raf);
		if (stream) stream.getTracks().forEach((track) => track.stop());
		if (detector?.dispose) detector.dispose();
	}

	return { mounted: mountedHook, destroyed };
}
