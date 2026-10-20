// Мониторы ведущего для зрителей (displays.js, SHARE-PROTOCOL §4.1): нумерация как у Mac и relay по общей фикстуре
// displays.json (копия relay/tests/fixtures/displays.json из development; если рядом есть и сам relay — сверяется с ним),
// список без имён и ID устройств, источник по номеру, уведомление.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const monitors = require("../displays");

const fixturePath = path.join(__dirname, "fixtures", "displays.json");
const fixture = JSON.parse(fs.readFileSync(fixturePath, "utf8"));

test("фикстура — та же, что у relay и Mac (когда relay рядом)", (t) => {
  const shared = path.join(__dirname, "..", "..", "relay", "tests", "fixtures", "displays.json");
  if (!fs.existsSync(shared)) return t.skip("relay/tests/fixtures/displays.json в этой ветке нет");
  assert.equal(fs.readFileSync(fixturePath, "utf8"), fs.readFileSync(shared, "utf8"));
});

test("нумерация по фикстуре: слева направо, затем сверху вниз", () => {
  for (const layout of fixture.numbering) {
    const displays = layout.screens.map((s, i) => ({ id: i + 1, key: s.key, bounds: { x: s.at[0], y: s.at[1], width: s.at[2], height: s.at[3] } }));
    assert.deepEqual(monitors.numbered(displays).map((d) => d.display.key), layout.expected, layout.about);
  }
});

// Раскладка Кати (журнал 1.1.17): A 1920×1080 @1 слева, B 3840×2160 @1,75 основной (2195×1235 DIP), C 1920×1080 @1 справа.
const A = { id: 2779098405, scaleFactor: 1, bounds: { x: -1920, y: 248, width: 1920, height: 1080 }, phys: { x: -1920, y: 435, width: 1920, height: 1080 } };
const B = { id: 2779098406, scaleFactor: 1.75, bounds: { x: 0, y: 0, width: 2195, height: 1235 }, phys: { x: 0, y: 0, width: 3840, height: 2160 } };
const C = { id: 2779098407, scaleFactor: 1, bounds: { x: 2195, y: 258, width: 1920, height: 1080 }, phys: { x: 3840, y: 452, width: 1920, height: 1080 } };
const physOf = (d) => d.phys;

test("смешанные DPI (Катя): номера A, B, C; пиксели физические, место — DIP, без ID устройств", () => {
  const list = monitors.list([B, C, A], B, physOf);
  assert.deepEqual(list, [
    { n: 1, primary: false, w: 1920, h: 1080, scale: 1, at: [-1920, 248, 1920, 1080] },
    { n: 2, primary: true, w: 3840, h: 2160, scale: 1.75, at: [0, 0, 2195, 1235] },
    { n: 3, primary: false, w: 1920, h: 1080, scale: 1, at: [2195, 258, 1920, 1080] },
  ]);
  assert.doesNotMatch(JSON.stringify(list), /277909840/);
  assert.equal(monitors.numberOf(C, [A, B, C]), 3);
  assert.equal(monitors.numberOf(null, [A, B, C]), 0);
});

test("больше восьми мониторов — первые восемь; масштаб и пиксели в пределах формата", () => {
  const many = Array.from({ length: 10 }, (_, i) => ({ id: i, scaleFactor: 9, bounds: { x: i * 100, y: 0, width: 100, height: 100 }, phys: { width: 40000, height: 0.2 } }));
  const list = monitors.list(many, many[0], physOf);
  assert.equal(list.length, 8);
  assert.equal(list[0].scale, 4);
  assert.equal(list[0].w, 32768);
  assert.equal(list[0].h, 1);
});

test("источник по номеру: по display_id, иначе по «Screen N» / «Экран N», один монитор — «Entire screen»", () => {
  const displays = [A, B, C];
  const byId = [{ id: "screen:0:0", name: "Screen 1", display_id: String(B.id) }, { id: "screen:1:0", name: "Screen 2", display_id: String(C.id) },
                { id: "screen:2:0", name: "Screen 3", display_id: String(A.id) }, { id: "window:5:0", name: "Screen 3", display_id: "" }];
  assert.equal(monitors.sourceFor(1, byId, displays).id, "screen:2:0");
  assert.equal(monitors.sourceFor(3, byId, displays).id, "screen:1:0");
  const byName = [{ id: "screen:0:0", name: "Экран 1", display_id: "" }, { id: "screen:1:0", name: "Экран 2", display_id: "" }, { id: "screen:2:0", name: "Экран 3", display_id: "" }];
  assert.equal(monitors.sourceFor(2, byName, displays).id, "screen:1:0");
  assert.equal(monitors.sourceFor(4, byName, displays), null);
  assert.equal(monitors.sourceFor(1, [{ id: "screen:0:0", name: "Entire screen", display_id: "" }], [B]).id, "screen:0:0");
  assert.equal(monitors.sourceFor(1, [{ id: "window:1:0", name: "Screen 1", display_id: "" }], [B]), null);
});

test("уведомление: имя как текст (до 60 символов), номер 1…8, мини-схема без лишних полей", () => {
  const list = monitors.list([A, B, C], B, physOf);
  assert.deepEqual(monitors.notice({ name: "  Максим ", n: 3, list }),
    { name: "Максим", n: 3, list: list.map((d) => ({ n: d.n, primary: d.primary, at: d.at })) });
  assert.equal(monitors.notice({ name: "x".repeat(100), n: 1, list: [] }).name.length, 60);
  assert.equal(monitors.notice({ name: "", n: 1 }).name, "Зритель");
  assert.equal(monitors.notice({ name: "x", n: 9, list }), null);
  assert.equal(monitors.notice({ name: "x", n: "2", list }), null);
  assert.equal(monitors.notice(null), null);
  assert.deepEqual(monitors.notice({ name: "x", n: 1, list: [{ n: 1, at: [0, 0, 0, 1] }, { n: 2, at: [0, 0, 10, 10], id: "secret" }] }).list,
    [{ n: 2, primary: false, at: [0, 0, 10, 10] }]);
});
