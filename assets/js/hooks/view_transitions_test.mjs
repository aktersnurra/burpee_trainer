import test from "node:test";
import assert from "node:assert/strict";
import { viewTransitions, TITLE_NAME, HOME_TITLE } from "../view_transitions.mjs";

function fixture({ api = true, reduced = false } = {}) {
  let onClick;
  const log = [];
  const finish = [];
  const source = { style: {} };
  const title = { style: {} };
  const doc = {
    documentElement: { dataset: {} },
    addEventListener(name, callback, capture) {
      assert.equal(name, "click");
      assert.equal(capture, true);
      onClick = callback;
    },
    querySelector: (selector) => (selector === HOME_TITLE ? title : null),
  };
  if (api) {
    doc.startViewTransition = (update) => {
      log.push(["transition", doc.documentElement.dataset.vt, source.style.viewTransitionName, "vtHold" in doc.documentElement.dataset]);
      update();
      let done;
      const finished = new Promise((resolve) => (done = resolve));
      finish.push(done);
      return { finished };
    };
  }
  const win = { matchMedia: () => ({ matches: reduced }), setTimeout: () => {} };
  const vt = viewTransitions(doc, win);
  const tap = (direction, from) =>
    onClick({
      target: {
        closest: () =>
          direction
            ? {
                dataset: { vt: direction, vtFrom: from },
                querySelector: (s) => (s === from ? source : null),
              }
            : null,
      },
    });
  const patch = () =>
    vt.onDocumentPatch(() =>
      log.push(["update", source.style.viewTransitionName, title.style.viewTransitionName, "vtHold" in doc.documentElement.dataset]),
    );
  return { doc, log, finish, tap, patch, source, title };
}

const settle = () => new Promise((resolve) => setImmediate(resolve));

test("a tap on a marked control moves the update it causes, then clears the direction", async () => {
  const f = fixture();
  f.tap("rise");
  f.patch();
  assert.deepEqual(f.log, [["transition", "rise", undefined, false], ["update", undefined, undefined, false]]);

  f.finish[0]();
  await settle();
  assert.equal(f.doc.documentElement.dataset.vt, undefined);

  // Only that one update: the next one, a pushed refresh, just applies.
  f.patch();
  assert.equal(f.log.length, 3);
  assert.equal(f.log.at(-1)[0], "update");
});

test("the workout's name travels: named on its source before the update, on Home's title after", async () => {
  const f = fixture();
  f.tap("attach", ".home-alternative-name");
  // The drawer is held where it is from the tap until the update applies.
  assert.ok("vtHold" in f.doc.documentElement.dataset);
  f.patch();
  // Before: the row's name carries it, the drawer held; during the update the name moves to
  // Home's title and the drawer lets go.
  assert.deepEqual(f.log[0], ["transition", "attach", TITLE_NAME, true]);
  assert.deepEqual(f.log[1], ["update", "", undefined, false]);
  assert.equal(f.title.style.viewTransitionName, TITLE_NAME);

  f.finish[0]();
  await settle();
  assert.equal(f.title.style.viewTransitionName, "");
});

test("unmarked taps, reduced motion and browsers without the API just update", () => {
  for (const [opts, direction] of [[{}, null], [{ reduced: true }, "drop"], [{ api: false }, "drop"]]) {
    const f = fixture(opts);
    f.tap(direction, ".home-alternative-name");
    f.patch();
    assert.deepEqual(f.log, [["update", undefined, undefined, false]]);
    assert.equal(f.doc.documentElement.dataset.vt, undefined);
  }
});

test("a tap that caused no update does not move a later one", (t) => {
  t.mock.timers.enable({ apis: ["Date"] });
  const f = fixture();
  f.tap("forward");
  t.mock.timers.tick(1500);
  f.patch();
  assert.deepEqual(f.log, [["update", undefined, undefined, false]]);
});
