// Чистые функции размещения меток (overlay-place.js): какой монитор транслируется и где область в окне меток.
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

test("область относительно фактического окна меток, точка зрителя — доля области", () => {
  const area = place.region({ x: -1700, y: 400, width: 1000, height: 700 }, { x: -1920, y: 133, width: 1920, height: 1080 });
  assert.deepEqual(area, { x: 220, y: 267, w: 1000, h: 700 });
  assert.deepEqual(place.markPoint([0, 0], area), [220, 267]);
  assert.deepEqual(place.markPoint([1, 1], area), [1220, 967]);
  assert.deepEqual(place.markPoint([0.5, 0.25], area), [720, 442]);
  assert.ok(place.same({ x: 1, y: 2, width: 3, height: 4 }, { x: 1, y: 2, width: 3, height: 4 }));
  assert.ok(!place.same({ x: 1, y: 2, width: 3, height: 4 }, { x: 1, y: 2, width: 3, height: 5 }));
});
