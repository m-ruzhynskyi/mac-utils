// Чистые функции размещения меток (overlay-place.js): какой монитор транслируется, на каком мониторе область и где
// она долями окна меток.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const place = require("../overlay-place");

const d = (id, x, y, width, height) => ({ id, bounds: { x, y, width, height } });
const primary = d(1, 0, 0, 1707, 1067), left = d(2, -1920, 133, 1920, 1080), right = d(3, 1707, 0, 1280, 720);
const displays = [primary, left, right];

test("монитор: по display_id, по номеру «Screen N» слева направо, иначе основной; окно — null", () => {
  assert.equal(place.sharedDisplay({ id: "screen:5:0", name: "Screen 1", display_id: "3" }, displays, primary), right);
  assert.equal(place.sharedDisplay({ id: "screen:5:0", name: "Screen 1", display_id: "" }, displays, primary), left);
  assert.equal(place.sharedDisplay({ id: "screen:5:0", name: "Screen 3", display_id: "99" }, displays, primary), right);
  assert.equal(place.sharedDisplay({ id: "screen:0:0", name: "Entire screen", display_id: "" }, displays, primary), primary);
  assert.equal(place.sharedDisplay({ id: "window:42:0", name: "Screen 2", display_id: "2" }, displays, primary), null);
  assert.equal(place.sharedDisplay(undefined, displays, primary), primary);
});

// Физические рамки мониторов ведущей: A @1 слева, B @1,75 основной, C @1 справа.
const A = { x: -1920, y: 435, width: 1920, height: 1080 }, B = { x: 0, y: 0, width: 3840, height: 2160 }, C = { x: 3840, y: 452, width: 1920, height: 1080 };

test("монитор области: где большая часть; вне всех мониторов — ближайший", () => {
  assert.equal(place.monitorOf(A, [A, B, C]), A);
  assert.equal(place.monitorOf({ x: -300, y: 500, width: 1000, height: 600 }, [A, B, C]), B);
  assert.equal(place.monitorOf({ x: 3700, y: 500, width: 1000, height: 600 }, [A, B, C]), C);
  assert.equal(place.monitorOf({ x: 9000, y: 500, width: 100, height: 100 }, [A, B, C]), C);
});

test("доли монитора → область на холсте любого размера; точка зрителя — доля области", () => {
  assert.deepEqual(place.fractions(A, A), { fx: 0, fy: 0, fw: 1, fh: 1 });
  const f = place.fractions({ x: 960, y: 540, width: 1920, height: 1080 }, B);
  assert.deepEqual(f, { fx: 0.25, fy: 0.25, fw: 0.5, fh: 0.5 });
  // Окно меток на B: страница при DPR 1,75 (2194x1234) и при ошибочном DPR 1 (3840x2160) — та же доля окна.
  for (const [w, h] of [[2194, 1234], [3840, 2160]]) {
    const [x, y] = place.markPoint([0.5, 0.5], place.areaIn(f, w, h));
    assert.ok(Math.abs(x / w - 0.5) < 1e-9 && Math.abs(y / h - 0.5) < 1e-9);
  }
  assert.deepEqual(place.markPoint([0.5, 0.25], { x: 220, y: 267, w: 1000, h: 700 }), [720, 442]);
  assert.ok(place.same({ x: 1, y: 2, width: 3, height: 4 }, { x: 1, y: 2, width: 3, height: 4 }));
  assert.ok(!place.same({ x: 1, y: 2, width: 3, height: 4 }, { x: 1, y: 2, width: 3, height: 5 }));
});
