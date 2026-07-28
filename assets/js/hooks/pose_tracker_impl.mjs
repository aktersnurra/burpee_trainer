import { createBlazePoseDetector } from "./blazepose_detector.mjs";
import { initialCounterState, countRep } from "./pose_rep_counter.mjs";
import { initialPoseReadiness, stepPoseReadiness } from "./pose_readiness.mjs";
import {
	initialStartGesture,
	stepStartGesture,
} from "./pose_start_gesture.mjs";
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

const CAMERA_SETUP_AUTO_CONFIRM_MS = 1500;

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
	const scheduleTimeout =
		runtime.setTimeout || ((cb, ms) => setTimeout(cb, ms));
	const clearScheduledTimeout = runtime.clearTimeout || clearTimeout;
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
	let armedStep = null;
	let armedHoldFramesRequired = 0;
	let startGesture = initialStartGesture();
	let autoConfirmTimeoutId = null;
	let startedAt = null;
	let trackingState = "lost";
	let mounted = false;
	let running = false;
	let startGeneration = 0;
	let lastPoseMs = -Infinity;
	let lastFeature = null;
	let captureSegment = null;
	let captureRecorder = initialPoseCaptureRecorder({ flushIntervalMs: 3000 });

	const dispatchLocal = (type, detail) => {
		hook.el.dispatchEvent(new CustomEvent(type, { bubbles: true, detail }));
	};

	const onCaptureSegment = (event) => {
		captureSegment = event.detail?.segment || null;
	};

	const reset = () => {
		state = initialCounterState();
		lastFeature = null;
	};

	const stopCameraSetupAutoConfirmTimer = () => {
		if (autoConfirmTimeoutId === null) return;
		clearScheduledTimeout(autoConfirmTimeoutId);
		autoConfirmTimeoutId = null;
	};

	const clearArmState = () => {
		stopCameraSetupAutoConfirmTimer();
		armedStep = null;
		armedHoldFramesRequired = 0;
		startGesture = initialStartGesture();
	};

	const readyForGesture = () =>
		lastReadinessStatus === "ready" || lastReadinessStatus === "optimal";

	const confirmArmedStep = (expectedStep) => {
		if (armedStep !== expectedStep) return false;
		if (expectedStep === "camera_setup" && !readyForGesture()) return false;
		const step = armedStep;
		clearArmState();
		dispatchLocal("pose-tracker:gesture-confirm", { step });
		return true;
	};

	const startCameraSetupAutoConfirmTimer = () => {
		if (autoConfirmTimeoutId !== null || !readyForGesture()) return;
		autoConfirmTimeoutId = scheduleTimeout(() => {
			autoConfirmTimeoutId = null;
			confirmArmedStep("camera_setup");
		}, CAMERA_SETUP_AUTO_CONFIRM_MS);
	};

	const armStep = (event) => {
		clearArmState();
		const detail = event.detail || {};
		armedStep = detail.step || null;
		armedHoldFramesRequired = detail.holdFramesRequired || 0;
		if (armedStep === "camera_setup") startCameraSetupAutoConfirmTimer();
	};

	function markLost(reason) {
		delete hook.el.dataset.poseTrackerReady;
		readiness = initialPoseReadiness();
		lastReadinessStatus = readiness.status;
		stopCameraSetupAutoConfirmTimer();
		startGesture = initialStartGesture();
		trackingState = "lost";
		dispatchLocal("pose-tracker:readiness", { state: "not_ready" });
		dispatchLocal("pose-tracker:status", { state: "lost", reason });
	}

	function releaseResources() {
		if (raf !== null) cancelFrame(raf);
		raf = null;
		if (stream) stream.getTracks().forEach((track) => track.stop());
		stream = null;
		if (video) video.srcObject = null;
		if (detector?.dispose) detector.dispose();
		detector = null;
		video = null;
		canvas = null;
		startedAt = null;
	}

	async function start() {
		if (!mounted || running) return;
		running = true;
		const generation = ++startGeneration;

		try {
			if (!hasWebgl()) {
				throw new Error(
					"WebGL is unavailable; BlazePose cannot start in this browser/context",
				);
			}

			const requestedStream = await requestPreferredCameraStream(mediaDevices);
			if (!mounted || !running || generation !== startGeneration) {
				requestedStream.getTracks().forEach((track) => track.stop());
				return;
			}
			stream = requestedStream;

			video = resolvePreviewVideo(hook);
			video.srcObject = stream;
			await video.play();
			await waitForFrame(video);
			if (!mounted || !running || generation !== startGeneration) return;

			canvas = hook.el.querySelector("#pose-tracker-canvas");
			if (!canvas) throw new Error("Pose tracker canvas is unavailable");
			resizePoseCanvas(canvas);

			const createdDetector = await createDetector();
			if (!mounted || !running || generation !== startGeneration) {
				createdDetector?.dispose?.();
				return;
			}
			detector = createdDetector;

			startedAt = now();
			dispatchLocal("pose-tracker:started", {});
			loop(generation);
		} catch (error) {
			if (!mounted || generation !== startGeneration) return;
			running = false;
			const reason = error?.message || error?.name || "tracker_error";
			markLost(reason);
			releaseResources();
			dispatchLocal("pose-tracker:start-failed", { reason });
		}
	}

	async function loop(generation) {
		if (
			!mounted ||
			!running ||
			generation !== startGeneration ||
			!detector ||
			!video ||
			startedAt === null
		) {
			return;
		}

		const scheduleNextFrame = () => {
			if (!mounted || !running || generation !== startGeneration) return;
			raf = requestFrame(() => loop(generation));
		};

		const sampledAt = now();
		if (!shouldSamplePose(sampledAt, lastPoseMs)) {
			scheduleNextFrame();
			return;
		}
		lastPoseMs = sampledAt;

		let poses;
		try {
			poses = await detector.estimatePoses(video);
		} catch (_error) {
			if (!mounted || !running || generation !== startGeneration) return;
			running = false;
			markLost("detector_error");
			releaseResources();
			return;
		}
		if (!mounted || !running || generation !== startGeneration) return;

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
			const ready = readyForGesture();
			if (ready) hook.el.dataset.poseTrackerReady = "true";
			else delete hook.el.dataset.poseTrackerReady;

			if (armedStep === "camera_setup") {
				if (ready) startCameraSetupAutoConfirmTimer();
				else stopCameraSetupAutoConfirmTimer();
			}

			dispatchLocal("pose-tracker:readiness", {
				state: nextReadiness.status,
			});
		}

		if (armedStep && armedHoldFramesRequired > 0) {
			const step = armedStep;
			const wasSatisfied = startGesture.satisfied;
			startGesture = stepStartGesture(startGesture, {
				sample,
				holdFramesRequired: armedHoldFramesRequired,
			});
			if (startGesture.satisfied && !wasSatisfied) confirmArmedStep(step);
		}

		if (captureSegment) {
			const recorded = recordPoseSample(captureRecorder, sample, {
				segment: captureSegment,
				nowMs: sample.tMs,
			});
			captureRecorder = recorded.state;
			recorded.chunks.forEach(dispatchCaptureChunk);
		}

		if (sample.confidence < 0.5 && trackingState !== "lost") {
			markLost("confidence_lost");
		}

		if (sample.confidence >= 0.5 && trackingState !== "live") {
			trackingState = "live";
			dispatchLocal("pose-tracker:status", { state: "live" });
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

		scheduleNextFrame();
	}

	function finish(event) {
		const elapsedMs = startedAt === null ? 0 : now() - startedAt;
		const flushed = flushPoseCaptureRecorder(captureRecorder, {
			reason: "finish",
			nowMs: elapsedMs,
		});
		captureRecorder = flushed.state;
		flushed.chunks.forEach(dispatchCaptureChunk);

		try {
			dispatchLocal(
				"pose-tracker:finished",
				trackingFinishPayload(event.detail || {}),
			);
		} catch (_error) {
			markLost("invalid_finish");
		}
	}

	function dispatchCaptureChunk(chunk) {
		dispatchLocal("pose-tracker:trace-chunk", { chunk });
	}

	function stop() {
		startGeneration += 1;
		running = false;
		clearArmState();
		delete hook.el.dataset.poseTrackerReady;
		readiness = initialPoseReadiness();
		lastReadinessStatus = readiness.status;
		trackingState = "lost";
		lastPoseMs = -Infinity;
		releaseResources();
	}

	async function mountedHook() {
		if (mounted) return;
		mounted = true;
		hook.el.addEventListener("pose-tracker:start", start);
		hook.el.addEventListener("pose-tracker:stop", stop);
		hook.el.addEventListener("pose-tracker:finish", finish);
		hook.el.addEventListener("pose-tracker:reset", reset);
		hook.el.addEventListener("pose-tracker:arm", armStep);
		document.addEventListener("pose-capture:segment", onCaptureSegment);
	}

	function destroyed() {
		if (!mounted) return;
		stop();
		mounted = false;
		hook.el.removeEventListener("pose-tracker:start", start);
		hook.el.removeEventListener("pose-tracker:stop", stop);
		hook.el.removeEventListener("pose-tracker:finish", finish);
		hook.el.removeEventListener("pose-tracker:reset", reset);
		hook.el.removeEventListener("pose-tracker:arm", armStep);
		document.removeEventListener("pose-capture:segment", onCaptureSegment);
	}

	return { mounted: mountedHook, start, stop, destroyed };
}
