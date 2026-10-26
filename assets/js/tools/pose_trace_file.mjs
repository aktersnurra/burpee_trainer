import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { gunzipSync } from "node:zlib";

// A recorded session: a session fixture or a `mix burpee_trainer.export_pose_corpus` file.
// Frames are what the counter received, with `{ reset: true }` where it was reset; a
// version 1 trace has only the usable frames.
export function loadTraceFile(path) {
	const raw = readFileSync(path);
	const data = JSON.parse(path.endsWith(".gz") ? gunzipSync(raw) : raw);

	return {
		path,
		sessionId: data.session_id ?? null,
		completedAt: data.completed_at ?? null,
		reps: data.reps ?? data.reps_logged ?? null,
		repsPlanned: data.reps_planned ?? null,
		version: data.version ?? 1,
		program: data.program ?? null,
		cameraCadenceMs: data.cadence_ms ?? null,
		liveRepsMs: data.camera_reps_ms ?? null,
		frames: data.samples.map(frameFromSample),
	};
}

export function traceFilesIn(paths) {
	return paths.flatMap((path) =>
		statSync(path).isDirectory()
			? readdirSync(path)
					.filter((name) => name.endsWith(".json.gz"))
					.sort()
					.map((name) => join(path, name))
			: [path],
	);
}

function frameFromSample(sample) {
	return sample.features ?? sample;
}
