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

export function drawPoseOverlay(canvas, pose, video, ink = poseOverlayInk()) {
	const context = canvas.getContext("2d");
	const rect = canvas.getBoundingClientRect();
	context.clearRect(0, 0, rect.width, rect.height);
	if (!pose?.keypoints) return;

	const points = new Map(
		pose.keypoints.map((point) => [point.name || point.part, point]),
	);

	context.save();
	context.scale(-1, 1);
	context.translate(-rect.width, 0);
	context.lineWidth = 3;
	context.strokeStyle = ink;

	for (const [aName, bName] of EDGES) {
		const a = points.get(aName);
		const b = points.get(bName);
		if (!visible(a) || !visible(b)) continue;

		context.beginPath();
		context.moveTo(scaleX(a.x, video, rect), scaleY(a.y, video, rect));
		context.lineTo(scaleX(b.x, video, rect), scaleY(b.y, video, rect));
		context.stroke();
	}

	for (const point of pose.keypoints) {
		if (!visible(point)) continue;

		context.fillStyle = ink;
		context.beginPath();
		context.arc(
			scaleX(point.x, video, rect),
			scaleY(point.y, video, rect),
			5,
			0,
			Math.PI * 2,
		);
		context.fill();
	}

	context.restore();
}

function poseOverlayInk() {
	return (
		globalThis
			.getComputedStyle?.(globalThis.document?.documentElement)
			.getPropertyValue("--color-base-content")
			.trim() || "#20201D"
	);
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
