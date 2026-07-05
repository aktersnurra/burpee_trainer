import { createBlazePoseDetector } from "./blazepose_detector.mjs";
import { initialCounterState, countRep } from "./pose_rep_counter.mjs";
import { sampleFromPose } from "./pose_signal.mjs";
import { buildFinishPayload } from "./pose_trace.mjs";
import { shouldSamplePose } from "./pose_sampler.mjs";
import { waitForVideoFrame, webglAvailable } from "./pose_video.mjs";
import {
	flushPoseCaptureRecorder,
	initialPoseCaptureRecorder,
	recordPoseSample,
} from "./pose_capture_recorder.mjs";

function configurePreviewVideo(video) {
	video.muted = true;
	video.playsInline = true;
	video.autoplay = true;
	video.setAttribute?.("playsinline", "");
	video.setAttribute?.("autoplay", "");
	return video;
}

export function resolvePreviewVideo(hook) {
	const existing =
		globalThis.document?.getElementById?.("pose-tracker-preview") ||
		hook.el.querySelector?.("#pose-tracker-preview");

	if (existing) return configurePreviewVideo(existing);

	const video = configurePreviewVideo(document.createElement("video"));
	video.id = "pose-tracker-preview";
	video.className = "absolute inset-0 h-full w-full object-cover scale-x-[-1]";
	hook.el.append?.(video);
	return video;
}

function stopStream(stream) {
	stream?.getTracks?.().forEach((track) => track.stop?.());
}

function ultraWideDevice(devices) {
	return (devices || []).find(
		(device) =>
			device.kind === "videoinput" &&
			/(ultra\s*wide|ultrawide|0\.5)/i.test(device.label || ""),
	);
}

async function applyMinimumZoom(stream) {
	const [track] = stream?.getVideoTracks?.() || [];
	const zoom = track?.getCapabilities?.().zoom;

	if (!zoom || !Number.isFinite(zoom.min) || !track.applyConstraints) return;

	try {
		await track.applyConstraints({ advanced: [{ zoom: zoom.min }] });
	} catch (_error) {
		// Some mobile browsers expose zoom capabilities but reject applying them.
	}
}

export async function requestPreferredCameraStream(mediaDevices) {
	let stream;

	try {
		stream = await mediaDevices.getUserMedia({
			video: { facingMode: { ideal: "environment" } },
			audio: false,
		});
	} catch (_error) {
		stream = await mediaDevices.getUserMedia({
			video: { facingMode: "user" },
			audio: false,
		});
	}

	try {
		const device = ultraWideDevice(await mediaDevices.enumerateDevices?.());

		if (device?.deviceId) {
			const wideStream = await mediaDevices.getUserMedia({
				video: {
					deviceId: { exact: device.deviceId },
					facingMode: { ideal: "environment" },
				},
				audio: false,
			});
			stopStream(stream);
			stream = wideStream;
		}
	} catch (_error) {
		// Device labels and lens selection are best-effort; keep the initial stream.
	}

	await applyMinimumZoom(stream);
	return stream;
}

export function createPoseTracker(hook) {
	let stream = null;
	let detector = null;
	let video = null;
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
