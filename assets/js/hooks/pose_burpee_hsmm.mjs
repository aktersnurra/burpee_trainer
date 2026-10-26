import { BURPEE_HSMM_MODEL } from "./pose_burpee_hsmm_model.mjs";

// An explicit-duration HSMM over burpee phases, decoded online by fixed-lag Viterbi.
// See docs/specs/2026-10-26-burpee-hsmm-design.md.

const PHASES = Object.freeze([
	"standing",
	"lowering",
	"pushup",
	"rising",
	"other",
]);

const NEXT = Object.freeze({
	standing: ["lowering", "other"],
	lowering: ["pushup"],
	pushup: ["rising"],
	rising: ["standing"],
	other: ["standing"],
});

export const BURPEE_HSMM_FEATURES = Object.freeze([
	"worldBodyVerticalSpan",
	"worldHipVerticalSpan",
	"worldTorsoElevation",
	"worldWristVerticalSpan",
	"dWorldBodyVerticalSpan",
	"dWorldWristVerticalSpan",
]);

const MIN_CONFIDENCE = 0.5;
const MIN_MACRO_LANDMARK_CONFIDENCE = 0.5;
const MIN_VISIBLE_FRACTION = 0.35;
// Phases a counted cycle must have been seen in, at least two of them.
const REP_PHASE_BITS = Object.freeze({ lowering: 1, pushup: 2, rising: 4 });
const MIN_SEEN_REP_PHASES = 2;
const LOG_SQRT_2PI = 0.5 * Math.log(2 * Math.PI);

const topologies = new WeakMap();

export function initialBurpeeHsmmState(model = BURPEE_HSMM_MODEL) {
	const { states, start } = topologyFor(model);
	return {
		model,
		phase: "standing",
		tick: null,
		pending: null,
		delta: states.map((_, index) => (index === start ? 0 : -Infinity)),
		history: [],
		cycle: idleCycle(),
		cadenceMs: [],
	};
}

// Feeds one frame; returns the reps (ms) committed by it, which lag it by the model's lag.
export function stepBurpeeHsmm(state, frame) {
	if (!Number.isFinite(frame?.tMs)) return { state, reps: [] };

	const tick = Math.floor(frame.tMs / state.model.tickMs);
	let current = state.tick === null ? { ...state, tick } : state;
	const reps = [];

	while (tick > current.tick) {
		const closed = closeTick(current);
		current = { ...closed.state, tick: current.tick + 1, pending: null };
		reps.push(...closed.reps);
	}

	return { state: addToPending(current, frame), reps };
}

// Commits every tick still inside the lag, as at the end of a recording.
export function flushBurpeeHsmm(state) {
	if (state.tick === null) return { state, reps: [] };

	const closed = closeTick(state);
	const { states } = topologyFor(state.model);
	let current = closed.state;
	const reps = [...closed.reps];
	const path = traceBack(current.delta, current.history);

	current.history.forEach((entry, index) => {
		const committed = commit(current, entry, states[path[index]].phase);
		current = committed.state;
		reps.push(...committed.reps);
	});

	return {
		state: { ...current, tick: null, pending: null, history: [] },
		reps,
	};
}

// Offline Viterbi over a whole recording: the phase of every tick, and the reps it counts.
export function segmentBurpeeHsmm(frames, model = BURPEE_HSMM_MODEL) {
	const { states, preds, start } = topologyFor(model);
	const ticks = evidenceByTick(frames, model);
	let delta = states.map((_, index) => (index === start ? 0 : -Infinity));
	const backs = [];

	for (const { evidence } of ticks) {
		const stepped = viterbiStep(delta, evidence, states, preds);
		delta = stepped.delta;
		backs.push(stepped.back);
	}

	const path = new Array(ticks.length);
	let index = argmax(delta);
	for (let t = ticks.length - 1; t >= 0; t--) {
		path[t] = index;
		index = backs[t][index];
	}

	let counter = initialBurpeeHsmmState(model);
	const phases = ticks.map(({ tick, evidence }, t) => {
		const phase = states[path[t]].phase;
		counter = commit(counter, { tick, observed: evidence !== null }, phase).state;
		return { tMs: tick * model.tickMs, phase, observed: evidence !== null };
	});

	return { phases, reps: counter.cadenceMs };
}

export function usableBurpeeHsmmFrame(frame) {
	return (
		Number.isFinite(frame?.tMs) &&
		frame?.hasFullWorldLandmarkCoverage === true &&
		finiteOr(frame.poseConfidence, frame.confidence) >= MIN_CONFIDENCE &&
		finiteOr(frame.macroLandmarkConfidence, 0) >=
			MIN_MACRO_LANDMARK_CONFIDENCE &&
		finiteOr(frame.visibleFraction, 0) >= MIN_VISIBLE_FRACTION &&
		BURPEE_HSMM_FEATURES.every((name) => Number.isFinite(frame[name]))
	);
}

export function phaseLogLikelihoods(model, frame) {
	const logInlier = Math.log(1 - model.outlierWeight);
	const logOutlier = Math.log(model.outlierWeight) + model.outlierLogDensity;

	return PHASES.map((phase) => {
		const { mean, sd } = model.emissions[phase];
		let gaussian = logInlier;
		BURPEE_HSMM_FEATURES.forEach((name, index) => {
			const z = (frame[name] - mean[index]) / sd[index];
			gaussian -= 0.5 * z * z + Math.log(sd[index]) + LOG_SQRT_2PI;
		});
		return logAddExp(gaussian, logOutlier);
	});
}

function addToPending(state, frame) {
	if (!usableBurpeeHsmmFrame(frame)) return state;

	const likelihoods = phaseLogLikelihoods(state.model, frame);
	const pending = state.pending
		? {
				sum: state.pending.sum.map((value, index) => value + likelihoods[index]),
				count: state.pending.count + 1,
			}
		: { sum: likelihoods, count: 1 };

	return { ...state, pending };
}

// A tick's evidence is the mean phase log-likelihood of its usable frames, so the weight of
// a tick does not depend on the frame rate.
function pendingEvidence(pending) {
	return pending ? pending.sum.map((value) => value / pending.count) : null;
}

function closeTick(state) {
	const { states, preds } = topologyFor(state.model);
	const evidence = pendingEvidence(state.pending);
	const { delta, back } = viterbiStep(state.delta, evidence, states, preds);
	const history = [
		...state.history,
		{ tick: state.tick, observed: evidence !== null, back },
	];
	let current = { ...state, delta, history };

	if (history.length <= state.model.lagTicks) return { state: current, reps: [] };

	const path = traceBack(delta, history);
	const committed = commit(current, history[0], states[path[0]].phase);
	current = { ...committed.state, history: history.slice(1) };
	return { state: current, reps: committed.reps };
}

function viterbiStep(delta, evidence, states, preds) {
	const next = new Array(states.length);
	const back = new Int16Array(states.length);

	for (let index = 0; index < states.length; index++) {
		let best = -Infinity;
		let from = 0;
		for (const [pred, logProbability] of preds[index]) {
			const score = delta[pred] + logProbability;
			if (score > best) {
				best = score;
				from = pred;
			}
		}
		next[index] = best + (evidence ? evidence[states[index].phaseIndex] : 0);
		back[index] = from;
	}

	const top = Math.max(...next);
	return { delta: next.map((value) => value - top), back };
}

// The best path's state at each history entry, oldest first.
function traceBack(delta, history) {
	const path = new Array(history.length);
	let index = argmax(delta);
	for (let entry = history.length - 1; entry >= 0; entry--) {
		path[entry] = index;
		index = history[entry].back[index];
	}
	return path;
}

// Commits one tick's phase; `state.phase` is the latest committed phase.
function commit(previous, { tick, observed }, phase) {
	const state = { ...previous, phase };
	const cycle = state.cycle;

	if (phase === "standing") {
		if (!cycle.active) return { state, reps: [] };
		const returnTick = cycle.returnTick ?? tick;
		if (!observed) return { state: { ...state, cycle: { ...cycle, returnTick } }, reps: [] };

		const counted = cycle.rose && seenCount(cycle.seen) >= MIN_SEEN_REP_PHASES;
		const repMs = returnTick * state.model.tickMs;
		return {
			state: {
				...state,
				cycle: idleCycle(),
				cadenceMs: counted ? state.cadenceMs.concat(repMs) : state.cadenceMs,
			},
			reps: counted ? [repMs] : [],
		};
	}

	if (phase === "other") return { state: { ...state, cycle: idleCycle() }, reps: [] };

	const base = cycle.returnTick === null ? cycle : idleCycle();
	return {
		state: {
			...state,
			cycle: {
				active: true,
				rose: base.rose || phase === "rising",
				seen: observed ? base.seen | REP_PHASE_BITS[phase] : base.seen,
				returnTick: null,
			},
		},
		reps: [],
	};
}

function idleCycle() {
	return { active: false, rose: false, seen: 0, returnTick: null };
}

function seenCount(bits) {
	let count = 0;
	for (let rest = bits; rest; rest >>= 1) count += rest & 1;
	return count;
}

function evidenceByTick(frames, model) {
	const ticks = [];
	let state = { model, tick: null, pending: null };

	for (const frame of frames) {
		if (!Number.isFinite(frame?.tMs)) continue;
		const tick = Math.floor(frame.tMs / model.tickMs);
		if (state.tick === null) state = { ...state, tick };
		while (tick > state.tick) {
			ticks.push({ tick: state.tick, evidence: pendingEvidence(state.pending) });
			state = { ...state, tick: state.tick + 1, pending: null };
		}
		state = addToPending(state, frame);
	}
	if (state.tick !== null) {
		ticks.push({ tick: state.tick, evidence: pendingEvidence(state.pending) });
	}

	return ticks;
}

// Each phase is a chain of minTicks sub-states; the last one loops, then leaves along NEXT.
function topologyFor(model) {
	const cached = topologies.get(model);
	if (cached) return cached;

	const states = PHASES.flatMap((phase, phaseIndex) =>
		Array.from({ length: model.minTicks[phase] }, (_, step) => ({
			phase,
			phaseIndex,
			step,
			last: step === model.minTicks[phase] - 1,
		})),
	);
	const indexOf = (phase, step) =>
		states.findIndex((state) => state.phase === phase && state.step === step);
	const preds = states.map(() => []);

	states.forEach((state, index) => {
		if (!state.last) {
			preds[index + 1].push([index, 0]);
			return;
		}
		const leave = model.leave[state.phase];
		preds[index].push([index, Math.log(1 - leave)]);
		for (const next of NEXT[state.phase]) {
			const branch = model.branch[state.phase]?.[next] ?? 1;
			preds[indexOf(next, 0)].push([index, Math.log(leave * branch)]);
		}
	});

	const topology = {
		states,
		preds,
		start: indexOf("standing", model.minTicks.standing - 1),
	};
	topologies.set(model, topology);
	return topology;
}

function argmax(values) {
	let best = 0;
	for (let index = 1; index < values.length; index++) {
		if (values[index] > values[best]) best = index;
	}
	return best;
}

function logAddExp(a, b) {
	const top = Math.max(a, b);
	return top + Math.log(Math.exp(a - top) + Math.exp(b - top));
}

function finiteOr(value, fallback) {
	return Number.isFinite(value) ? value : fallback;
}

export { PHASES };
