# Home's drawer and the studio: browser end-to-end check

The unit and LiveView tests cannot see layout, gestures or the keyboard. This check drives Home's
drawer and the studio (Edit and New) in a phone-sized browser against a real server, and fails
when something is off. It is not part of `mix precommit`; run it after changing Home, the studio,
the composer or the CSS around them.

## What it checks

- Collapsed Home is the workout and Play alone; opening the workout shows Swap, Edit and New.
- On a phone the drawer is a sheet: Swap opens it, a pull down closes it, and a sideways swipe
  (the tablet's gesture) does nothing.
- Edit: the studio starts at Home's left edge, the docked box starts at the same edge, nothing
  scrolls sideways, a spinner shows while the coach works, and Save and Run sit under the proposal.
- New: one form with Create, sets and pace as rows in the open, an even beat has no set size and
  unbroken asks for one, a value's buttons move it by a step, a held button keeps stepping, a value can be typed,
  the form says what the values make, nothing scrolls sideways, and Run starts the workout.
- Every button and form control is big enough to hit (at least 40px on both sides and 44px on one;
  parts are exempt) and the browser logs no errors.

## Run it

Needs Playwright with Chromium (`npm i -D playwright` anywhere on the module path, or `NODE_PATH`).

```bash
DIR=$(mktemp -d)
export PREVIEW_DIR=$DIR BURPEE_TRAINER_TEST_DATABASE_PATH=$DIR/e2e.db MIX_ENV=test
mix ecto.create && mix ecto.migrate
mix run --no-start scripts/e2e/studio_preview.exs &        # serves until killed; writes $DIR/preview.json
until [ -f $DIR/preview.json ]; do sleep 1; done
SHOTS_DIR=$DIR/shots node scripts/e2e/studio_journey.mjs   # exit 1 if a check fails
kill %1
```

`studio_preview.exs` seeds two athletes (one trained today) and stubs the coach, so no provider call
is made and nothing is paid for. It uses the scratch database only; never point it at a real one.
The server is on `PORT` (default 4000); set `BASE_URL` for another origin. `SHOTS_DIR` keeps a
screenshot of each stage.

Sign-in is a server-signed session cookie for the seeded athlete, not Pocket ID. It proves the
screens, not authentication.

## What it cannot check

A desktop browser has no on-screen keyboard and no iOS edge swipe. Those are in
`docs/guides/ios-device-check.md`.
