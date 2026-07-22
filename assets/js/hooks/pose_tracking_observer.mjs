export function initialTrackingObserver() {
	return {
		mode: "idle",
		trackerStatus: "lost",
		readiness: "not_ready",
		cadenceMs: [],
		lastIndex: null,
		lastTimestampMs: null,
		degradedReason: null,
	};
}

export function updateTrackingStatus(state, status) {
	if (status !== "live" && status !== "lost") return state;
	if (state.mode === "observing" && status === "lost") {
		return degrade({ ...state, trackerStatus: status }, "tracking_lost");
	}
	return { ...state, trackerStatus: status };
}

export function updateTrackingReadiness(state, readiness) {
	if (!["not_ready", "ready", "optimal"].includes(readiness)) return state;
	const next = { ...state, readiness };
	if (state.mode === "observing" && readiness === "not_ready") {
		return degrade(next, "pose_not_ready");
	}
	return next;
}

export function startTrackingObserver(state, readiness) {
	const next = {
		...initialTrackingObserver(),
		trackerStatus: state.trackerStatus,
		readiness,
	};
	if (state.trackerStatus !== "live") return degrade(next, "tracker_not_live");
	if (readiness !== "ready" && readiness !== "optimal") {
		return degrade(next, "pose_not_ready");
	}
	return { ...next, mode: "observing" };
}

export function observeTrackingRep(state, { index, elapsedMs, eligible }) {
	if (state.mode !== "observing" || !eligible) return state;
	if (!Number.isInteger(index) || index <= 0)
		return degrade(state, "invalid_index");
	if (!Number.isInteger(elapsedMs) || elapsedMs < 0) {
		return degrade(state, "invalid_timestamp");
	}
	if (state.lastIndex !== null && index <= state.lastIndex) {
		return degrade(state, "duplicate_index");
	}
	if (state.lastTimestampMs !== null && elapsedMs < state.lastTimestampMs) {
		return degrade(state, "decreasing_timestamp");
	}

	return {
		...state,
		cadenceMs: [...state.cadenceMs, elapsedMs],
		lastIndex: index,
		lastTimestampMs: elapsedMs,
	};
}

export function finishTrackingObserver(state, durationMs) {
	let finished = state;
	if (!Number.isInteger(durationMs) || durationMs < 0) {
		finished = degrade(state, "invalid_duration");
	} else if (state.cadenceMs.some((timestamp) => timestamp > durationMs)) {
		finished = degrade(state, "timestamp_beyond_duration");
	}

	const trusted = finished.mode === "observing" && !finished.degradedReason;
	return {
		state: { ...finished, mode: "finished" },
		result: {
			trusted,
			cadenceMs: trusted ? [...finished.cadenceMs] : [],
			reason: trusted
				? null
				: finished.degradedReason || "tracking_unavailable",
		},
	};
}

function degrade(state, reason) {
	return {
		...state,
		mode: "degraded",
		degradedReason: state.degradedReason || reason,
	};
}
