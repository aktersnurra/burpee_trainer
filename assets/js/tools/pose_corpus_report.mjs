// Replays recorded sessions through the current rep counter and reports how it does.
//
//   node assets/js/tools/pose_corpus_report.mjs FILE_OR_DIR...
//
// Files are `mix burpee_trainer.export_pose_corpus` exports or session fixtures. Per
// session: logged reps, the session's camera count, the replayed count; for a version 2
// trace whether the replay reproduces the reps the camera emitted live; and the replay
// matched to the program's schedule (the schedule is a rep-by-rep label only where the
// athlete kept up).

import {
	BURPEE_HSMM_FEATURES,
	flushBurpeeHsmm,
	initialBurpeeHsmmState,
	stepBurpeeHsmm,
} from "../hooks/pose_burpee_hsmm.mjs";
import { loadTraceFile, traceFilesIn } from "./pose_trace_file.mjs";

// The workout starts with a reset; frames before it carried the warm-up's counter state.
export function replayTrace(frames) {
	const firstReset = frames.findIndex((frame) => frame.reset);
	let state = initialBurpeeHsmmState();
	const live = [];
	for (const frame of firstReset >= 0 ? frames.slice(firstReset) : frames) {
		if (frame.reset) {
			state = initialBurpeeHsmmState();
			continue;
		}
		const result = stepBurpeeHsmm(state, frame);
		state = result.state;
		live.push(...result.reps);
	}
	return {
		live,
		all: live.concat(flushBurpeeHsmm(state).reps),
		fromMs: firstReset >= 0 ? frames[firstReset].tMs : -Infinity,
	};
}

// Every scheduled rep: when it is due to finish and its interval, in ms from the start.
export function scheduledReps(program) {
	const reps = [];
	let clockMs = 0;
	for (const event of program?.events ?? []) {
		if (event.kind === "work") {
			const intervalMs =
				event.sec_per_rep_us != null ? event.sec_per_rep_us / 1_000 : event.sec_per_rep * 1_000;
			for (let index = 1; index <= event.reps; index++) {
				reps.push({ atMs: clockMs + index * intervalMs, intervalMs });
			}
			clockMs += event.reps * intervalMs;
		} else if (event.kind === "rest") {
			clockMs += event.duration_ms ?? event.duration_sec * 1_000;
		}
	}
	return reps;
}

// One-to-one nearest matches within half an interval, in time order.
export function matchSchedule(detectionsMs, schedule, offsetMs) {
	let detection = 0;
	let matched = 0;
	for (const slot of schedule) {
		const at = slot.atMs + offsetMs;
		const window = slot.intervalMs / 2;
		while (detection < detectionsMs.length && detectionsMs[detection] < at - window) detection++;
		if (detection < detectionsMs.length && detectionsMs[detection] <= at + window) {
			matched++;
			detection++;
		}
	}
	return { matched, missed: schedule.length - matched, extra: detectionsMs.length - matched };
}

// The trace clock starts before the workout; try the offsets that pair an early detection
// with an early scheduled rep, then refine around the best.
export function alignSchedule(detectionsMs, schedule) {
	if (detectionsMs.length === 0 || schedule.length === 0) return null;
	const candidates = detectionsMs
		.slice(0, 10)
		.flatMap((detection) => schedule.slice(0, 10).map((slot) => detection - slot.atMs));
	const best = (offsets) =>
		offsets
			.map((offsetMs) => ({ offsetMs, ...matchSchedule(detectionsMs, schedule, offsetMs) }))
			.reduce((a, b) => (b.matched > a.matched ? b : a));
	const coarse = best(candidates);
	return best(
		Array.from({ length: 41 }, (_, index) => coarse.offsetMs + (index - 20) * 100),
	);
}

export function reportTrace(trace) {
	// Captures from before world landmarks were recorded cannot be replayed at all.
	const replayable = trace.frames.some((frame) => Number.isFinite(frame[BURPEE_HSMM_FEATURES[0]]));
	const replay = replayTrace(trace.frames);
	const schedule = scheduledReps(trace.program);
	return {
		name: trace.sessionId ? `session ${trace.sessionId}` : trace.path.split("/").at(-1),
		date: trace.completedAt?.slice(0, 10) ?? "",
		logged: trace.reps,
		camera: trace.cameraCadenceMs?.length ?? null,
		replayable,
		replayed: replay.all.length,
		reproducesLive:
			trace.version >= 2 && trace.liveRepsMs
				? JSON.stringify(replay.live) ===
					JSON.stringify(trace.liveRepsMs.filter((repMs) => repMs >= replay.fromMs))
				: null,
		schedule: alignSchedule(replay.all, schedule),
	};
}

function formatRow(row) {
	if (!row.replayable) return `${row.name.padEnd(36)} ${row.date.padEnd(10)} logged ${String(row.logged).padStart(4)}  no world features; not replayable`;
	const cell = (value) => (value === null || value === undefined ? "–" : String(value));
	const schedule = row.schedule
		? `${row.schedule.matched} matched, ${row.schedule.missed} missed, ${row.schedule.extra} extra`
		: "no schedule";
	const live =
		row.reproducesLive === null ? "v1 trace" : row.reproducesLive ? "replay = live" : "REPLAY ≠ LIVE";
	return `${row.name.padEnd(36)} ${row.date.padEnd(10)} logged ${cell(row.logged).padStart(4)}  camera ${cell(row.camera).padStart(4)}  replay ${cell(row.replayed).padStart(4)}  ${live.padEnd(13)}  ${schedule}`;
}

if (import.meta.url === new URL(process.argv[1], "file://").href) {
	const all = traceFilesIn(process.argv.slice(2)).map((path) => reportTrace(loadTraceFile(path)));
	all.forEach((row) => console.log(formatRow(row)));
	const rows = all.filter((row) => row.replayable);

	const counted = rows.filter((row) => Number.isInteger(row.logged));
	const error = counted.reduce((sum, row) => sum + Math.abs(row.replayed - row.logged), 0);
	const scheduled = rows.filter((row) => row.schedule);
	const total = (key) => scheduled.reduce((sum, row) => sum + row.schedule[key], 0);
	console.log(
		`\n${rows.length} replayable sessions; replay off the logged count by ${error} reps in total` +
			(scheduled.length
				? `; against the schedule: ${total("matched")} matched, ${total("missed")} missed, ${total("extra")} extra`
				: ""),
	);
	if (rows.some((row) => row.reproducesLive === false)) process.exitCode = 1;
}
