import test from "node:test";
import assert from "node:assert/strict";
import { viewTransitions } from "../view_transitions.mjs";

function fixture({ api = true, reduced = false } = {}) {
  let onClick;
  const log = [];
  const finish = [];
  const doc = {
    documentElement: { dataset: {} },
    addEventListener(name, callback, capture) {
      assert.equal(name, "click");
      assert.equal(capture, true);
      onClick = callback;
    },
  };
  if (api) {
    doc.startViewTransition = (update) => {
      log.push(["transition", doc.documentElement.dataset.vt]);
      update();
      let done;
      const finished = new Promise((resolve) => (done = resolve));
      finish.push(done);
      return { finished };
    };
  }
  const win = { matchMedia: () => ({ matches: reduced }) };
  const vt = viewTransitions(doc, win);
  const tap = (direction) =>
    onClick({ target: { closest: () => (direction ? { dataset: { vt: direction } } : null) } });
  const patch = () => vt.onDocumentPatch(() => log.push(["update"]));
  return { doc, log, finish, tap, patch };
}

test("a tap on a marked control slides the update it causes, then clears the direction", async () => {
  const f = fixture();
  f.tap("forward");
  f.patch();
  assert.deepEqual(f.log, [["transition", "forward"], ["update"]]);

  f.finish[0]();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(f.doc.documentElement.dataset.vt, undefined);

  // Only that one update: the next one, a pushed refresh, just applies.
  f.patch();
  assert.deepEqual(f.log.at(-1), ["update"]);
  assert.equal(f.log.length, 3);
});

test("unmarked taps, reduced motion and browsers without the API just update", () => {
  for (const [opts, direction] of [[{}, null], [{ reduced: true }, "back"], [{ api: false }, "back"]]) {
    const f = fixture(opts);
    f.tap(direction);
    f.patch();
    assert.deepEqual(f.log, [["update"]]);
    assert.equal(f.doc.documentElement.dataset.vt, undefined);
  }
});

test("a tap that caused no update does not slide a later one", (t) => {
  t.mock.timers.enable({ apis: ["Date"] });
  const f = fixture();
  f.tap("forward");
  t.mock.timers.tick(1500);
  f.patch();
  assert.deepEqual(f.log, [["update"]]);
});
