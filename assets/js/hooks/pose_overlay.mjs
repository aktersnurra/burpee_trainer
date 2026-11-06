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

export function resizePoseCanvas(
	canvas,
	scale = globalThis.window?.devicePixelRatio || 1,
) {
	const rect = canvas.getBoundingClientRect();
	canvas.width = Math.round(rect.width * scale);
	canvas.height = Math.round(rect.height * scale);
	canvas.getContext("2d").setTransform(scale, 0, 0, scale, 0, 0);
}

// The pose on camera setup, drawn over the feed: a fine line with a soft glow, ringed joints and
// a ring round the head, in the runner's light ink while it looks for you, then in the pace's
// green, glowing brighter with filled joints, once it has you. While it looks, a scan line
// passes down your body (the caller passes its place, 0 to 1, or null under reduced motion).
const INK = [244, 242, 238];
const READY = [144, 169, 89];
const JOINTS = new Set([
	"left_shoulder",
	"right_shoulder",
	"left_elbow",
	"right_elbow",
	"left_wrist",
	"right_wrist",
	"left_hip",
	"right_hip",
	"left_knee",
	"right_knee",
	"left_ankle",
	"right_ankle",
]);
const FACE = ["nose", "left_eye", "right_eye", "left_ear", "right_ear"];

export function drawPoseOverlay(
	canvas,
	pose,
	video,
	{ ready = false, scan = null } = {},
) {
	const context = canvas.getContext("2d");
	const rect = canvas.getBoundingClientRect();
	context.clearRect(0, 0, rect.width, rect.height);
	if (!pose?.keypoints) return;

	const at = new Map();
	for (const point of pose.keypoints) {
		if (visible(point))
			at.set(point.name || point.part, [
				scaleX(point.x, video, rect),
				scaleY(point.y, video, rect),
			]);
	}
	const rgba = (alpha) =>
		`rgba(${(ready ? READY : INK).join(", ")}, ${alpha})`;
	const bones = () => {
		context.beginPath();
		for (const [aName, bName] of EDGES) {
			const a = at.get(aName);
			const b = at.get(bName);
			if (!a || !b) continue;
			context.moveTo(a[0], a[1]);
			context.lineTo(b[0], b[1]);
		}
	};

	context.save();
	context.scale(-1, 1);
	context.translate(-rect.width, 0);
	context.lineCap = "round";
	context.lineJoin = "round";

	// Bones: a glow under a crisp line, and a white core once it has you.
	context.save();
	context.shadowColor = rgba(ready ? 0.85 : 0.35);
	context.shadowBlur = ready ? 20 : 8;
	context.strokeStyle = rgba(ready ? 0.95 : 0.6);
	context.lineWidth = 2;
	bones();
	context.stroke();
	context.restore();
	if (ready) {
		context.strokeStyle = "rgba(255, 255, 255, 0.25)";
		context.lineWidth = 1;
		bones();
		context.stroke();
	}

	// Joints: small rings, filled once it has you.
	for (const [name, [x, y]] of at) {
		if (!JOINTS.has(name)) continue;
		context.beginPath();
		context.arc(x, y, 3.5, 0, Math.PI * 2);
		context.fillStyle = ready ? rgba(1) : "rgba(38, 39, 34, 0.6)";
		context.fill();
		context.strokeStyle = rgba(1);
		context.lineWidth = 1.5;
		context.stroke();
	}

	// The head: a ring round the face points, sized by the shoulders.
	const face = FACE.map((name) => at.get(name)).filter(Boolean);
	const ls = at.get("left_shoulder");
	const rs = at.get("right_shoulder");
	if (face.length > 0 && ls && rs) {
		const cx = face.reduce((sum, [x]) => sum + x, 0) / face.length;
		const cy = face.reduce((sum, [, y]) => sum + y, 0) / face.length;
		context.save();
		context.shadowColor = rgba(ready ? 0.8 : 0.4);
		context.shadowBlur = 12;
		context.strokeStyle = rgba(ready ? 1 : 0.6);
		context.lineWidth = 1.5;
		context.beginPath();
		context.arc(cx, cy, Math.hypot(rs[0] - ls[0], rs[1] - ls[1]) * 0.3, 0, Math.PI * 2);
		context.stroke();
		context.restore();
	}

	// While it looks for you, a scan line passes down the body.
	if (!ready && scan !== null && at.size > 1) {
		const ys = [...at.values()].map(([, y]) => y);
		const xs = [...at.values()].map(([x]) => x);
		const top = Math.min(...ys);
		const y = top + (Math.max(...ys) - top) * scan;
		const mid = (Math.min(...xs) + Math.max(...xs)) / 2;
		const half = Math.max(40, (Math.max(...xs) - Math.min(...xs)) * 0.7);
		const glow = context.createLinearGradient(mid - half, 0, mid + half, 0);
		glow.addColorStop(0, rgba(0));
		glow.addColorStop(0.5, rgba(0.85));
		glow.addColorStop(1, rgba(0));
		context.save();
		context.shadowColor = rgba(0.8);
		context.shadowBlur = 12;
		context.strokeStyle = glow;
		context.lineWidth = 1.5;
		context.beginPath();
		context.moveTo(mid - half, y);
		context.lineTo(mid + half, y);
		context.stroke();
		context.restore();
	}

	context.restore();
}

function visible(point) {
	return (
		point &&
		(point.score === null || point.score === undefined || point.score >= 0.25)
	);
}

function scaleX(x, video, rect) {
	return (x / (video.videoWidth || 1)) * rect.width;
}

function scaleY(y, video, rect) {
	return (y / (video.videoHeight || 1)) * rect.height;
}
