# Session Runner Reliability Research

## Current Boundary

`BurpeeTrainerWeb.SessionLive` computes the workout timeline once and pushes it to the client via `session_ready`. `assets/js/hooks/session_hook.js` owns the running clock, warmup insertion, counters, beeps, and completion payload.

Server events include:

- `warmup_requested` returns `warmup_ready`.
- `session_started` parses mood and marks phase running.
- `session_complete` accepts client-provided main/warmup counts and durations.
- `validate_session` and `save_session` validate/persist completion form data.

## Likely Failure Modes

- `session_complete` trusts map shape and numeric payloads from the client. Missing or string values currently fall through with defaults or may persist surprising values.
- Warmup session creation happens before main session save. If warmup insert succeeds and main insert fails, the workout can be partially recorded.
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
- `save_session` still creates warmup and main session for valid completion data.

## Defer

Do not redesign the JS timer or persistence transaction in the first slice. A later reliability pass can make warmup + main save transactional if the product requires all-or-nothing recording.
