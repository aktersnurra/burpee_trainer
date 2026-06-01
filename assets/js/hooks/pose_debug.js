import { ensureTfBackend } from "./tf_backend.mjs";
import { initialCounterState, countRep } from "./pose_rep_counter.mjs";
import { sampleFromPose } from "./pose_signal.mjs";
import {
	initialTemplateMatcherState,
	recordTemplateSample,
	finishTemplateRecording,
	matchTemplateWindow,
} from "./pose_template_matcher.mjs";

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
		this.templateRecording = initialTemplateMatcherState();
		this.template = null;
		this.templateRecordingActive = false;
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

		this.status("Requesting camera");

		try {
			this.stream = await navigator.mediaDevices.getUserMedia({
				video: { facingMode: "user" },
				audio: false,
			});
			this.video.srcObject = this.stream;
			await this.video.play();
			this.resizeCanvas();

			this.status("Initializing TFJS");
			const backend = await ensureTfBackend();
			const poseDetection = await import("@tensorflow-models/pose-detection");

			this.status(`Loading model (${backend})`);
			this.detector = await poseDetection.createDetector(
				poseDetection.SupportedModels.MoveNet,
				{
					modelType: poseDetection.movenet.modelType.SINGLEPOSE_LIGHTNING,
					modelUrl: "/models/movenet/model.json",
				},
			);

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
		this.el
			.querySelector("#pose-debug-template-start")
			?.addEventListener("click", () => this.startTemplateRecording());
		this.el
			.querySelector("#pose-debug-template-finish")
			?.addEventListener("click", () => this.finishTemplateRecording());
	},

	startTemplateRecording() {
		this.templateRecording = initialTemplateMatcherState();
		this.templateRecordingActive = true;
		this.template = null;
		this.dtwRepCount = 0;
		this.lastDtwUpTMs = null;
		setText(this.el, "#pose-debug-dtw-status", "Recording");
		setText(
			this.el,
			"#pose-debug-dtw-detail",
			"Do one clean rep, then save template.",
		);
		setText(this.el, "#pose-debug-dtw-reps", "0");
	},

	finishTemplateRecording() {
		this.templateRecordingActive = false;
		const result = finishTemplateRecording(this.templateRecording);

		if (!result.ok) {
			this.template = null;
			setText(this.el, "#pose-debug-dtw-status", `Rejected: ${result.reason}`);
			setText(
				this.el,
				"#pose-debug-dtw-detail",
				"Record a rep with clearer down/up movement.",
			);
			return;
		}

		this.template = result.template;
		this.dtwRepCount = 0;
		this.lastDtwUpTMs = null;
		setText(this.el, "#pose-debug-dtw-status", "Template ready");
		setText(
			this.el,
			"#pose-debug-dtw-detail",
			`template samples=${result.template.points.length} duration=${result.template.durationMs}ms`,
		);
		setText(this.el, "#pose-debug-dtw-reps", "0");
	},

	recordSample(sample) {
		this.sampleWindow.push(sample);
		const minTMs = sample.tMs - SAMPLE_WINDOW_MS;
		while (this.sampleWindow.length > 0 && this.sampleWindow[0].tMs < minTMs) {
			this.sampleWindow.shift();
		}

		if (this.templateRecordingActive) {
			this.templateRecording = recordTemplateSample(
				this.templateRecording,
				sample,
			);
			setText(
				this.el,
				"#pose-debug-dtw-detail",
				`recording samples=${this.templateRecording.samples.length}`,
			);
		}
	},

	matchTemplate() {
		if (!this.template || this.templateRecordingActive) return null;

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

export default PoseDebug;
