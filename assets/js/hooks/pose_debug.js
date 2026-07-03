import { createBlazePoseDetector } from "./blazepose_detector.mjs";
import { initialCounterState, countRep } from "./pose_rep_counter.mjs";
import { sampleFromPose } from "./pose_signal.mjs";
import { shouldSamplePose } from "./pose_sampler.mjs";
import { waitForVideoFrame, webglAvailable } from "./pose_video.mjs";
import { decodeBurpeePhases } from "./pose_phase_decoder.mjs";
import { extractBurpeeCandidates } from "./pose_candidate_extractor.mjs";
import { formatDecoderDiagnostics } from "./pose_decoder_diagnostics.mjs";
import { matchTemplateWindow } from "./pose_template_matcher.mjs";
import { drawPoseOverlay, resizePoseCanvas } from "./pose_overlay.mjs";
import {
	initialTemplateCalibration,
	startTemplateCalibration,
	stepTemplateCalibration,
} from "./pose_template_calibration.mjs";
import {
	initialTraceRecorder,
	startTraceRecording,
	stepTraceRecorder,
} from "./pose_trace_recorder.mjs";

const SAMPLE_WINDOW_MS = 6000;
const FEATURE_WINDOW_MS = 20000;
const DTW_REFRACTORY_MS = 1200;

const PoseDebug = {
	async mounted() {
		this.video = this.el.querySelector("#pose-debug-video");
		this.canvas = this.el.querySelector("#pose-debug-canvas");
		this.state = initialCounterState();
		this.calibration = initialTemplateCalibration();
		this.traceRecorder = initialTraceRecorder();
		this.template = null;
		this.sampleWindow = [];
		this.featureWindow = [];
		this.dtwRepCount = 0;
		this.lastDtwUpTMs = null;
		this.startedAt = null;
		this.lastFrameAt = null;
		this.lastPoseAt = -Infinity;
		this.lastFeature = null;
		this.raf = null;
		this.stream = null;
		this.detector = null;
		this.mountedFlag = true;
		this.bindTemplateControls();
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
		this.recordSample(sample);
		const decoderDiagnostics = this.updateDecoderDiagnostics(sample);
		this.stepCalibration(sample);
		this.stepTraceRecording(sample);
		const templateMatch = this.matchTemplate();

		this.draw(pose);
		this.renderStats(sample, now, templateMatch, decoderDiagnostics);
		this.raf = requestAnimationFrame(() => this.loop());
	},

	resizeCanvas() {
		resizePoseCanvas(this.canvas);
	},

	draw(pose) {
		drawPoseOverlay(this.canvas, pose, this.video);
	},

	bindTemplateControls() {
		this.el.addEventListener("pose-debug:start-calibration", () => {
			setText(document, "#pose-debug-template-start", "Tap received");
			this.startTemplateCalibration();
		});
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

	startTemplateCalibration() {
		const nowMs =
			this.startedAt == null ? 0 : performance.now() - this.startedAt;
		this.calibration = startTemplateCalibration(this.calibration, nowMs);
		this.template = null;
		this.dtwRepCount = 0;
		this.lastDtwUpTMs = null;
		setText(this.el, "#pose-debug-dtw-status", "Starting in 3s");
		setText(
			this.el,
			"#pose-debug-dtw-detail",
			"Put the phone down now. Do one clean rep after the countdown; it auto-saves.",
		);
		setText(this.el, "#pose-debug-dtw-reps", "0");
		setText(document, "#pose-debug-template-start", "Restart countdown");
	},

	recordSample(sample) {
		this.sampleWindow.push(sample);
		const minTMs = sample.tMs - SAMPLE_WINDOW_MS;
		while (this.sampleWindow.length > 0 && this.sampleWindow[0].tMs < minTMs) {
			this.sampleWindow.shift();
		}
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

	stepCalibration(sample) {
		const previousPhase = this.calibration.phase;
		const result = stepTemplateCalibration(this.calibration, sample);
		this.calibration = result.state;

		if (
			previousPhase !== this.calibration.phase ||
			this.calibration.phase !== "idle"
		) {
			setText(this.el, "#pose-debug-dtw-status", result.status);
		}

		if (this.calibration.phase === "recording") {
			setText(
				this.el,
				"#pose-debug-dtw-detail",
				`recording samples=${this.calibration.recording.samples.length}`,
			);
		}

		if (
			this.calibration.phase === "ready" &&
			this.template !== this.calibration.template
		) {
			this.template = this.calibration.template;
			this.dtwRepCount = 0;
			this.lastDtwUpTMs = null;
			setText(
				this.el,
				"#pose-debug-dtw-detail",
				`template samples=${this.template.points.length} duration=${this.template.durationMs}ms`,
			);
			setText(this.el, "#pose-debug-dtw-reps", "0");
		}

		if (this.calibration.phase === "failed") {
			this.template = null;
			setText(
				this.el,
				"#pose-debug-dtw-detail",
				"Try again with one clearer full-body rep.",
			);
		}
	},

	matchTemplate() {
		if (!this.template || this.calibration.phase === "recording") return null;

		const result = matchTemplateWindow(this.template, this.sampleWindow);
		if (
			result.ok &&
			(this.lastDtwUpTMs == null ||
				result.upTMs - this.lastDtwUpTMs >= DTW_REFRACTORY_MS)
		) {
			this.dtwRepCount += 1;
			this.lastDtwUpTMs = result.upTMs;
		}

		return result;
	},

	renderStats(sample, now, templateMatch, decoderDiagnostics) {
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
		this.renderTemplateMatch(templateMatch);
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

	renderTemplateMatch(templateMatch) {
		if (this.templateRecordingActive) return;
		if (!this.template) return;

		setText(this.el, "#pose-debug-dtw-reps", String(this.dtwRepCount));
		if (!templateMatch) return;

		if (templateMatch.ok) {
			setText(this.el, "#pose-debug-dtw-status", "Match");
			setText(
				this.el,
				"#pose-debug-dtw-detail",
				JSON.stringify({
					distance: Number(templateMatch.distance.toFixed(3)),
					downTMs: templateMatch.downTMs,
					upTMs: templateMatch.upTMs,
				}),
			);
			return;
		}

		setText(this.el, "#pose-debug-dtw-status", "Watching");
		setText(
			this.el,
			"#pose-debug-dtw-detail",
			JSON.stringify({
				reason: templateMatch.reason,
				distance:
					templateMatch.distance == null
						? null
						: Number(templateMatch.distance.toFixed(3)),
			}),
		);
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
