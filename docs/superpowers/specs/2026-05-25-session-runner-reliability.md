# Session Runner Reliability Research

## Current Boundary

`BurpeeTrainerWeb.SessionLive` loads the persisted workout plan and pushes serialized plan data to the client via `session_ready`. `assets/js/hooks/session_hook.js` derives warmup/workout timelines and owns the running clock, counters, beeps, and completion payload.

Server events include:

- `session_started` marks phase running.
- `session_complete` accepts client-provided main/warmup counts and durations.
- `validate_session` and `save_session` validate/persist completion form data.

## Likely Failure Modes

- `session_complete` trusts map shape and numeric payloads from the client. Missing or string values currently fall through with defaults or may persist surprising values.
- Warmup is client-only execution data and should not be persisted as a separate workout session.
- Client owns timing, so refresh/navigation during a workout loses in-progress state.
- Completion payload and completion form params are parsed in separate places.

## Recommended Next Slice

Start with server-side payload parsing for `session_complete`:

- Add a pure parser module or private function that accepts `%{"main" => ..., "warmup" => ...}`.
- Return `{:ok, parsed}` or `{:error, reason}`.
- Ensure counts/durations are non-negative integers.
- Keep existing successful behavior unchanged.
- On invalid payload, keep the session in a safe phase and show an error flash instead of building a malformed completion form.

## Tests Needed

- Valid `session_complete` payload enters done phase and builds completion form.
- Missing warmup payload defaults to zero only if that is intentional.
- Negative or non-numeric counts/durations return an error and do not enter done phase.
- `save_session` creates only the main workout session for valid completion data.

## Defer

Do not redesign the JS timer in the first slice. Warmup remains client-only execution data unless the product explicitly adds warmup history later.
