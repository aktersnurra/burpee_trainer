import { createBlazePoseDetector } from "./blazepose_detector.mjs";
import { initialCounterState, countRep } from "./pose_rep_counter.mjs";
import { sampleFromPose } from "./pose_signal.mjs";
import { matchTemplateWindow } from "./pose_template_matcher.mjs";
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
const DTW_REFRACTORY_MS = 1200;

const EDGES = [
	["left_shoulder", "right_shoulder"],
	["left_shoulder", "left_elbow"],
	["left_elbow", "left_wrist"],
	["right_shoulder", "right_elbow"],
	["right_elbow", "right_wrist"],
	["left_shoulder", "left_hip"],
	["right_shoulder", "right_hip"],
	["left_hip", "right_hip"],
	["left_hip", "left_knee"],
	["left_knee", "left_ankle"],
	["right_hip", "right_knee"],
	["right_knee", "right_ankle"],
];

const PoseDebug = {
	async mounted() {
		this.video = this.el.querySelector("#pose-debug-video");
		this.canvas = this.el.querySelector("#pose-debug-canvas");
		this.ctx = this.canvas.getContext("2d");
		this.state = initialCounterState();
		this.calibration = initialTemplateCalibration();
		this.traceRecorder = initialTraceRecorder();
		this.template = null;
		this.sampleWindow = [];
		this.dtwRepCount = 0;
		this.lastDtwUpTMs = null;
		this.startedAt = null;
		this.lastFrameAt = null;
		this.raf = null;
		this.stream = null;
		this.detector = null;
		this.mountedFlag = true;
		this.bindTemplateControls();
		this.bindTraceControls();

		this.status("Requesting camera");

		try {
			this.stream = await navigator.mediaDevices.getUserMedia({
				video: { facingMode: "user" },
				audio: false,
			});
			this.video.srcObject = this.stream;
			await this.video.play();
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
		const poses = await this.detector.estimatePoses(this.video);
		const pose = poses[0];
		const sample = sampleFromPose(pose, now - this.startedAt, this.video);
		const result = countRep(this.state, sample);
		this.state = result.state;
		this.recordSample(sample);
		this.stepCalibration(sample);
		this.stepTraceRecording(sample);
		const templateMatch = this.matchTemplate();

		this.draw(pose);
		this.renderStats(sample, now, templateMatch);
		this.raf = requestAnimationFrame(() => this.loop());
	},

	resizeCanvas() {
		const rect = this.canvas.getBoundingClientRect();
		const scale = window.devicePixelRatio || 1;
		this.canvas.width = Math.round(rect.width * scale);
		this.canvas.height = Math.round(rect.height * scale);
		this.ctx.setTransform(scale, 0, 0, scale, 0, 0);
	},

	draw(pose) {
		const rect = this.canvas.getBoundingClientRect();
		this.ctx.clearRect(0, 0, rect.width, rect.height);
		if (!pose?.keypoints) return;

		const points = new Map(
			pose.keypoints.map((point) => [point.name || point.part, point]),
		);

		this.ctx.save();
		this.ctx.scale(-1, 1);
		this.ctx.translate(-rect.width, 0);

		this.ctx.lineWidth = 3;
		this.ctx.strokeStyle = "#4A9EFF";
		for (const [aName, bName] of EDGES) {
			const a = points.get(aName);
			const b = points.get(bName);
			if (!visible(a) || !visible(b)) continue;
			this.ctx.beginPath();
			this.ctx.moveTo(
				scaleX(a.x, this.video, rect),
				scaleY(a.y, this.video, rect),
			);
			this.ctx.lineTo(
				scaleX(b.x, this.video, rect),
				scaleY(b.y, this.video, rect),
			);
			this.ctx.stroke();
		}

		for (const point of pose.keypoints) {
			if (!visible(point)) continue;
			this.ctx.fillStyle = "#C8D8F0";
			this.ctx.beginPath();
			this.ctx.arc(
				scaleX(point.x, this.video, rect),
				scaleY(point.y, this.video, rect),
				5,
				0,
				Math.PI * 2,
			);
			this.ctx.fill();
		}

		this.ctx.restore();
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

	renderStats(sample, now, templateMatch) {
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
		this.renderTemplateMatch(templateMatch);
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

function visible(point) {
	return point && (point.score == null || point.score >= 0.25);
}

function scaleX(x, video, rect) {
	return (x / (video.videoWidth || 1)) * rect.width;
}

function scaleY(y, video, rect) {
	return (y / (video.videoHeight || 1)) * rect.height;
}

function setText(root, selector, value) {
	const el = root.querySelector(selector);
	if (el) el.textContent = value;
}

function setValue(root, selector, value) {
	const el = root.querySelector(selector);
	if (el) el.value = value;
}

export default PoseDebug;
