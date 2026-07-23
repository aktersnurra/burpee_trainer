import { createBlazePoseDetector } from "./blazepose_detector.mjs";
import { initialCounterState, countRep } from "./pose_rep_counter.mjs";
import { initialPoseReadiness, stepPoseReadiness } from "./pose_readiness.mjs";
import { sampleFromPose } from "./pose_signal.mjs";
import { buildFinishPayload } from "./pose_trace.mjs";
import { drawPoseOverlay, resizePoseCanvas } from "./pose_overlay.mjs";
import { shouldSamplePose } from "./pose_sampler.mjs";
import { waitForVideoFrame, webglAvailable } from "./pose_video.mjs";
import {
	flushPoseCaptureRecorder,
	initialPoseCaptureRecorder,
	recordPoseSample,
} from "./pose_capture_recorder.mjs";

export { drawPoseOverlay, resizePoseCanvas };

export function trackingFinishPayload({ durationMs, cadenceMs }) {
	return buildFinishPayload({ durationMs, cadenceMs });
}

function configurePreviewVideo(video) {
	video.muted = true;
	video.playsInline = true;
	video.autoplay = true;
	video.setAttribute?.("playsinline", "");
	video.setAttribute?.("autoplay", "");
	return video;
}

export function previewDiagnostics(video) {
	const rect = video.getBoundingClientRect?.() || {};
	const dimension = (value) => (Number.isFinite(value) ? Math.round(value) : 0);

	return {
		connected: Boolean(video.isConnected),
		rendered_width: dimension(rect.width),
		rendered_height: dimension(rect.height),
		video_width: dimension(video.videoWidth),
		video_height: dimension(video.videoHeight),
		ready_state: Number.isInteger(video.readyState) ? video.readyState : 0,
		paused: Boolean(video.paused),
		parent_id: video.parentElement?.id || null,
	};
}

export function resolvePreviewVideo(hook) {
	const existing = hook.el.querySelector?.("#pose-tracker-preview");

	if (existing) return configurePreviewVideo(existing);

	const video = configurePreviewVideo(document.createElement("video"));
	video.id = "pose-tracker-preview";
	video.className = "absolute inset-0 h-full w-full object-cover scale-x-[-1]";
	hook.el.append?.(video);
	return video;
}

export function requestPreferredCameraStream(mediaDevices) {
	return mediaDevices.getUserMedia({
		video: { facingMode: "user" },
		audio: false,
	});
}

export function createPoseTracker(hook, runtime = {}) {
	const createDetector =
		runtime.createBlazePoseDetector || createBlazePoseDetector;
	const mediaDevices = runtime.mediaDevices || navigator.mediaDevices;
	const now = runtime.now || (() => performance.now());
	const requestFrame =
		runtime.requestAnimationFrame ||
		((callback) => requestAnimationFrame(callback));
	const cancelFrame = runtime.cancelAnimationFrame || cancelAnimationFrame;
	const poseSample = runtime.sampleFromPose || sampleFromPose;
	const waitForFrame = runtime.waitForVideoFrame || waitForVideoFrame;
	const hasWebgl = runtime.webglAvailable || webglAvailable;
	let stream = null;
	let detector = null;
	let video = null;
	let canvas = null;
	let raf = null;
	let state = initialCounterState();
	let candidateIndex = 0;
	let readiness = initialPoseReadiness();
	let lastReadinessStatus = readiness.status;
	let startedAt = null;
	let trackingState = "lost";
	let mounted = true;
	let lastPoseMs = -Infinity;
	let lastFeature = null;
	let captureSegment = null;
	let captureRecorder = initialPoseCaptureRecorder({ flushIntervalMs: 3000 });
	const onCaptureSegment = (event) => {
		captureSegment = event.detail?.segment || null;
	};
	const dispatchLocal = (type, detail) => {
		hook.el.dispatchEvent(new CustomEvent(type, { bubbles: true, detail }));
	};
	const reset = () => {
		state = initialCounterState();
		lastFeature = null;
	};

	async function mountedHook() {
		hook.el.addEventListener("pose-tracker:finish", finish);
		hook.el.addEventListener("pose-tracker:reset", reset);
		document.addEventListener("pose-capture:segment", onCaptureSegment);

		try {
			if (!hasWebgl()) {
				throw new Error(
					"WebGL is unavailable; BlazePose cannot start in this browser/context",
				);
			}

			stream = await requestPreferredCameraStream(mediaDevices);

			video = resolvePreviewVideo(hook);
			video.srcObject = stream;
			await video.play();
			await waitForFrame(video);

			canvas = hook.el.querySelector("#pose-tracker-canvas");
			if (!canvas) throw new Error("Pose tracker canvas is unavailable");
			resizePoseCanvas(canvas);
			hook.pushEvent("camera_preview_diagnostics", previewDiagnostics(video));

			detector = await createDetector();

			if (!mounted) return;
			startedAt = now();
			hook.pushEvent("tracker_initialized", {});
			loop();
		} catch (error) {
			delete hook.el.dataset.poseTrackerReady;
			console.error("PoseTracker failed", error);
			hook.pushEvent("track", {
				state: "lost",
				reason: error?.message || error?.name || "tracker_error",
			});
		}
	}

	async function loop() {
		if (!mounted || !detector || !video || startedAt === null) return;

		const sampledAt = now();
		if (!shouldSamplePose(sampledAt, lastPoseMs)) {
			raf = requestFrame(loop);
			return;
		}
		lastPoseMs = sampledAt;

		let poses = [];
		try {
			poses = await detector.estimatePoses(video);
		} catch (error) {
			console.error("BlazePose frame failed", error);
			hook.pushEvent("track", {
				state: "lost",
				reason: error?.message || "blazepose_frame_failed",
			});
			return;
		}
		drawPoseOverlay(canvas, poses[0], video);

		const sample = poseSample(
			poses[0],
			sampledAt - startedAt,
			video,
			lastFeature,
		);
		lastFeature = sample.features;

		const nextReadiness = stepPoseReadiness(readiness, {
			poseCount: poses.length,
			sample,
		});
		readiness = nextReadiness;

		if (nextReadiness.status !== lastReadinessStatus) {
			lastReadinessStatus = nextReadiness.status;
			const ready =
				nextReadiness.status === "ready" || nextReadiness.status === "optimal";
			if (ready) hook.el.dataset.poseTrackerReady = "true";
			else delete hook.el.dataset.poseTrackerReady;

			const detail = { state: nextReadiness.status };
			dispatchLocal("pose-tracker:readiness", detail);
			hook.pushEvent("tracker_readiness", detail);
		}

		if (captureSegment) {
			const recorded = recordPoseSample(captureRecorder, sample, {
				segment: captureSegment,
				nowMs: sample.tMs,
			});
			captureRecorder = recorded.state;
			recorded.chunks.forEach(pushCaptureChunk);
		}

		if (sample.confidence < 0.5 && trackingState !== "lost") {
			trackingState = "lost";
			hook.pushEvent("track", { state: "lost" });
			dispatchLocal("pose-tracker:status", { state: trackingState });
		}

		if (sample.confidence >= 0.5 && trackingState !== "live") {
			trackingState = "live";
			hook.pushEvent("track", { state: "live" });
			dispatchLocal("pose-tracker:status", { state: trackingState });
		}

		const result = countRep(state, sample);
		state = result.state;

		if (result.rep) {
			candidateIndex += 1;
			dispatchLocal("pose-tracker:rep", {
				index: candidateIndex,
				confidence: sample.confidence,
			});
		}

		raf = requestFrame(loop);
	}

	function finish(event) {
		const flushed = flushPoseCaptureRecorder(captureRecorder, {
			reason: "finish",
			nowMs: now() - (startedAt || now()),
		});
		captureRecorder = flushed.state;
		flushed.chunks.forEach(pushCaptureChunk);

		try {
			hook.pushEvent("finish", trackingFinishPayload(event.detail || {}));
		} catch (_error) {
			hook.pushEvent("track", { state: "lost", reason: "invalid_finish" });
		}
	}

	function pushCaptureChunk(chunk) {
		hook.pushEvent("pose_capture_chunk", chunk);
	}

	function destroyed() {
		mounted = false;
		delete hook.el.dataset.poseTrackerReady;
		hook.el.removeEventListener("pose-tracker:finish", finish);
		hook.el.removeEventListener("pose-tracker:reset", reset);
		document.removeEventListener("pose-capture:segment", onCaptureSegment);
		if (raf) cancelFrame(raf);
		if (stream) stream.getTracks().forEach((track) => track.stop());
		if (detector?.dispose) detector.dispose();
	}

	return { mounted: mountedHook, destroyed };
}
