import { createBlazePoseDetector } from "./blazepose_detector.mjs";
import { initialCounterState, countRep } from "./pose_rep_counter.mjs";
import { sampleFromPose } from "./pose_signal.mjs";
import { shouldSamplePose } from "./pose_sampler.mjs";
import { waitForVideoFrame, webglAvailable } from "./pose_video.mjs";
import { decodeBurpeePhases } from "./pose_phase_decoder.mjs";
import { extractBurpeeCandidates } from "./pose_candidate_extractor.mjs";
import { formatDecoderDiagnostics } from "./pose_decoder_diagnostics.mjs";
import { drawPoseOverlay, resizePoseCanvas } from "./pose_overlay.mjs";
import {
	initialTraceRecorder,
	startTraceRecording,
	stepTraceRecorder,
} from "./pose_trace_recorder.mjs";

const FEATURE_WINDOW_MS = 20000;

const PoseDebug = {
	async mounted() {
		this.video = this.el.querySelector("#pose-debug-video");
		this.canvas = this.el.querySelector("#pose-debug-canvas");
		this.state = initialCounterState();
		this.traceRecorder = initialTraceRecorder();
		this.featureWindow = [];
		this.startedAt = null;
		this.lastFrameAt = null;
		this.lastPoseAt = -Infinity;
		this.lastFeature = null;
		this.raf = null;
		this.stream = null;
		this.detector = null;
		this.mountedFlag = true;
		this.bindTraceControls();

		this.status("Requesting camera");

		try {
			if (!webglAvailable()) {
				throw new Error(
					"WebGL is unavailable; BlazePose cannot start in this browser/context",
				);
			}

			this.stream = await navigator.mediaDevices.getUserMedia({
				video: { facingMode: "user" },
				audio: false,
			});
			this.video.srcObject = this.stream;
			await this.video.play();
			await waitForVideoFrame(this.video);
			this.resizeCanvas();

			this.status("Loading BlazePose full");
			this.detector = await createBlazePoseDetector();

			this.startedAt = performance.now();
			this.status("Live");
			this.loop();
		} catch (error) {
			this.status(error?.message || error?.name || "Camera/model failed");
		}
	},

	destroyed() {
		this.mountedFlag = false;
		if (this.raf) cancelAnimationFrame(this.raf);
		if (this.stream) this.stream.getTracks().forEach((track) => track.stop());
		if (this.detector?.dispose) this.detector.dispose();
	},

	async loop() {
		if (!this.mountedFlag) return;

		const now = performance.now();
		if (!shouldSamplePose(now, this.lastPoseAt)) {
			this.raf = requestAnimationFrame(() => this.loop());
			return;
		}
		this.lastPoseAt = now;

		let poses = [];
		try {
			poses = await this.detector.estimatePoses(this.video);
		} catch (error) {
			console.error("BlazePose frame failed", error);
			this.status(error?.message || "BlazePose frame failed");
			return;
		}
		const pose = poses[0];
		const sample = sampleFromPose(
			pose,
			now - this.startedAt,
			this.video,
			this.lastFeature,
		);
		this.lastFeature = sample.features;
		const result = countRep(this.state, sample);
		this.state = result.state;
		const decoderDiagnostics = this.updateDecoderDiagnostics(sample);
		this.stepTraceRecording(sample);

		this.draw(pose);
		this.renderStats(sample, now, decoderDiagnostics);
		this.raf = requestAnimationFrame(() => this.loop());
	},

	resizeCanvas() {
		resizePoseCanvas(this.canvas);
	},

	draw(pose) {
		drawPoseOverlay(this.canvas, pose, this.video);
	},

	bindTraceControls() {
		this.el.addEventListener("pose-debug:start-trace", () => {
			setText(document, "#pose-debug-trace-start", "Trace tap received");
			this.startTraceRecording();
		});
	},

	startTraceRecording() {
		const nowMs =
			this.startedAt == null ? 0 : performance.now() - this.startedAt;
		this.traceRecorder = startTraceRecording(this.traceRecorder, nowMs);
		setText(this.el, "#pose-debug-trace-status", "Trace starts in 3s");
		setText(this.el, "#pose-debug-trace-count", "0");
		setValue(this.el, "#pose-debug-trace-output", "[]");
	},

	updateDecoderDiagnostics(sample) {
		if (!sample.features) return formatDecoderDiagnostics(null, []);

		this.featureWindow.push(sample.features);
		const minTMs = sample.tMs - FEATURE_WINDOW_MS;
		while (
			this.featureWindow.length > 0 &&
			this.featureWindow[0].tMs < minTMs
		) {
			this.featureWindow.shift();
		}

		const decoded = decodeBurpeePhases(this.featureWindow);
		const candidates = extractBurpeeCandidates(decoded);
		return formatDecoderDiagnostics(decoded, candidates);
	},

	stepTraceRecording(sample) {
		const previousPhase = this.traceRecorder.phase;
		const result = stepTraceRecorder(this.traceRecorder, sample);
		this.traceRecorder = result.state;

		if (
			previousPhase !== this.traceRecorder.phase ||
			this.traceRecorder.phase !== "idle"
		) {
			setText(this.el, "#pose-debug-trace-status", result.status);
		}

		if (this.traceRecorder.phase === "recording") {
			setText(
				this.el,
				"#pose-debug-trace-count",
				String(this.traceRecorder.samples.length),
			);
		}

		if (this.traceRecorder.phase === "complete" && this.traceRecorder.export) {
			setText(this.el, "#pose-debug-trace-status", "Trace ready");
			setText(
				this.el,
				"#pose-debug-trace-count",
				String(this.traceRecorder.export.samples.length),
			);
			setValue(
				this.el,
				"#pose-debug-trace-output",
				JSON.stringify(this.traceRecorder.export),
			);
			setText(document, "#pose-debug-trace-start", "Record 10s trace");
		}
	},

	renderStats(sample, now, decoderDiagnostics) {
		const fps = this.lastFrameAt ? 1000 / (now - this.lastFrameAt) : 0;
		this.lastFrameAt = now;
		setText(this.el, "#pose-debug-fps", fps ? fps.toFixed(1) : "—");
		setText(this.el, "#pose-debug-confidence", sample.confidence.toFixed(2));
		setText(this.el, "#pose-debug-signal", sample.signal.toFixed(2));
		setText(this.el, "#pose-debug-phase", this.state.phase);
		setText(this.el, "#pose-debug-reps", String(this.state.cadenceMs.length));
		setText(
			this.el,
			"#pose-debug-cadence",
			JSON.stringify(this.state.cadenceMs),
		);
		this.renderDecoderDiagnostics(decoderDiagnostics);
	},

	renderDecoderDiagnostics(diagnostics) {
		setText(this.el, "#pose-debug-decoder-phase", diagnostics.phase);
		setText(
			this.el,
			"#pose-debug-decoder-candidates",
			diagnostics.candidateCount,
		);
		setText(
			this.el,
			"#pose-debug-decoder-illegal-transitions",
			diagnostics.illegalTransitions,
		);
		setText(this.el, "#pose-debug-decoder-max-unknown", diagnostics.maxUnknown);
		setText(this.el, "#pose-debug-decoder-segments", diagnostics.segments);
	},

	status(value) {
		setText(this.el, "#pose-debug-status", value);
	},
};

function setText(root, selector, value) {
	const el = root.querySelector(selector);
	if (el) el.textContent = value;
}

function setValue(root, selector, value) {
	const el = root.querySelector(selector);
	if (el) el.value = value;
}

export default PoseDebug;
