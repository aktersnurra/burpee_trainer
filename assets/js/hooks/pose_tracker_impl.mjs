import { createBlazePoseDetector } from "./blazepose_detector.mjs";
import { initialCounterState, countRep } from "./pose_rep_counter.mjs";
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

async function applyMinimumSupportedZoom(stream) {
	const [track] = stream?.getVideoTracks?.() || [];

	if (!track?.applyConstraints) return;

	try {
		const capabilities = track.getCapabilities?.();
		const minimumZoom = capabilities?.zoom?.min;

		if (!Number.isFinite(minimumZoom)) return;

		await track.applyConstraints({ advanced: [{ zoom: minimumZoom }] });
	} catch (_error) {
		// Zoom is optional; preserve the working front-camera stream.
	}
}

export async function requestPreferredCameraStream(mediaDevices) {
	const stream = await mediaDevices.getUserMedia({
		video: { facingMode: "user" },
		audio: false,
	});

	await applyMinimumSupportedZoom(stream);
	return stream;
}

export function createPoseTracker(hook) {
	let stream = null;
	let detector = null;
	let video = null;
	let canvas = null;
	let raf = null;
	let state = initialCounterState();
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

	async function mountedHook() {
		hook.el.addEventListener("pose-tracker:finish", finish);
		document.addEventListener("pose-capture:segment", onCaptureSegment);

		try {
			if (!webglAvailable()) {
				throw new Error(
					"WebGL is unavailable; BlazePose cannot start in this browser/context",
				);
			}

			stream = await requestPreferredCameraStream(navigator.mediaDevices);

			video = resolvePreviewVideo(hook);
			video.srcObject = stream;
			await video.play();
			await waitForVideoFrame(video);

			canvas = hook.el.querySelector("#pose-tracker-canvas");
			if (!canvas) throw new Error("Pose tracker canvas is unavailable");
			resizePoseCanvas(canvas);
			hook.pushEvent("camera_preview_diagnostics", previewDiagnostics(video));

			detector = await createBlazePoseDetector();

			if (!mounted) return;
			startedAt = performance.now();
			hook.el.dataset.poseTrackerReady = "true";
			hook.pushEvent("tracker_ready", {});
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

		const now = performance.now();
		if (!shouldSamplePose(now, lastPoseMs)) {
			raf = requestAnimationFrame(loop);
			return;
		}
		lastPoseMs = now;

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

		const sample = sampleFromPose(
			poses[0],
			now - startedAt,
			video,
			lastFeature,
		);
		lastFeature = sample.features;

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
		const flushed = flushPoseCaptureRecorder(captureRecorder, {
			reason: "finish",
			nowMs: performance.now() - (startedAt || performance.now()),
		});
		captureRecorder = flushed.state;
		flushed.chunks.forEach(pushCaptureChunk);

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

	function pushCaptureChunk(chunk) {
		hook.pushEvent("pose_capture_chunk", chunk);
	}

	function destroyed() {
		mounted = false;
		delete hook.el.dataset.poseTrackerReady;
		hook.el.removeEventListener("pose-tracker:finish", finish);
		document.removeEventListener("pose-capture:segment", onCaptureSegment);
		if (raf) cancelAnimationFrame(raf);
		if (stream) stream.getTracks().forEach((track) => track.stop());
		if (detector?.dispose) detector.dispose();
	}

	return { mounted: mountedHook, destroyed };
}
