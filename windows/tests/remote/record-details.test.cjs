// Задачи 3–5 (task-rc-terminal-session), Windows: учётка Windows, «Доступ», «Контакты», RDP/VPN/«Другое», метки, фильтры, подробности.
// Все данные выдуманные; программы (AnyDesk, TeamViewer, mstsc) не запускаются — двойники процессов, буфера обмена и Electron.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { EventEmitter } = require("node:events");
const F = require("./fixtures");
const { fieldFor, isSecret } = require("../../remote/headers");
const { load, passwordFor, secretFor } = require("../../remote/source");
const { splitTags } = require("../../remote/builder");
const { ConnectionSearch } = require("../../remote/search");
const lists = require("../../remote/lists");
const models = require("../../remote/models");
const { tagKey, tagKind, displayTag, isBadgeTag } = require("../../remote/tags");
const rdp = require("../../remote/rdp");
const editor = require("../../remote/editor");
const templates = require("../../remote/templates");
const { createConnector } = require("../../remote/connect");
const { createSecretClipboard } = require("../../remote/clipboard");
const { SecretBuffer } = require("../../remote/secret");
const { RemoteSettings } = require("../../remote/settings");
const { RemoteService } = require("../../remote/service");
const { ConnectionsFileStore } = require("../../remote/filestore");
const { init } = require("../../remote");

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const ACCESS = "VPN (WireGuard) | профиль Выдуманный-1\n\nRDP — IP: 10.20.0.15\nServer — логин: lims.admin · пароль: Demo-77-выдумка\n\nLogin: operator";
const CONTACT = "Иван, 050 000 00 00";
const ROWS = [
  `<connection><name>Північна лабораторія</name><id>123456789</id><password>AD-pass-1</password><group>Північ</group><tags>Рег</tags><account>Администратор</account><accountPassword>Win-pass-1</accountPassword><contacts>${esc(CONTACT)}</contacts><app>AnyDesk</app></connection>`,
  `<connection><name>Вінницька · Філія 2</name><id>10.20.0.15</id><group>Вінницька</group><tags>рег., VPN, RDP, фіто</tags><account>lims.admin</account><accountPassword>Win-pass-2</accountPassword><access>${esc(ACCESS)}</access><app>RDP</app></connection>`,
  "<connection><name>Озерна</name><id></id><group>Вінницька</group><tags>Рег, Сервер</tags><note>Только по телефону</note><app>Другое</app></connection>",
  "<connection><name>Лісова</name><id></id><tags>РЕГ, VPN</tags><access>Профиль: лес</access><app>VPN</app></connection>",
  "<connection><name>Східна</name><id>987654321</id><tags>Фито, VPN</tags><app>TeamViewer</app></connection>",
];
const xml = (rows = ROWS) => Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>\n<connections>\n  ${rows.join("\n  ")}\n</connections>\n`, "utf8");
const FILE = xml();
const byName = (records) => Object.fromEntries(records.map((r) => [r.name, r]));
const text = (s) => { if (!s) return null; const t = Buffer.from(s.bytes).toString("utf8"); s.wipe(); return t; };
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), "rc-rd-"));
const SECRETS = ["AD-pass-1", "Win-pass-1", "Win-pass-2", "Demo-77", "WireGuard", "Профиль: лес", "050 000", "Иван,"];
const noSecrets = (value, label) => { const s = JSON.stringify(value); for (const x of SECRETS) assert.ok(!s.includes(x), `${label}: «${x}»`); };

// ---------- колонки ----------

test("колонки: учётка, пароль учётки, «Доступ», «Контакты» на ru/uk/en; голое «Пароль» — пароль AnyDesk/TV", () => {
  const cases = [
    ["Учётная запись", "account"], ["учетка", "account"], ["Логин", "account"], ["Логін", "account"], ["Користувач", "account"], ["Обліковий запис", "account"],
    ["Windows user", "account"], ["username", "account"], ["Login", "account"], ["User", "account"], ["Account", "account"],
    ["Пароль учётной записи", "accountPassword"], ["Пароль учетки", "accountPassword"], ["Пароль Windows", "accountPassword"],
    ["Пароль облікового запису", "accountPassword"], ["Account password", "accountPassword"], ["Windows password", "accountPassword"],
    ["Пароль", "password"], ["password", "password"],
    ["Доступ", "access"], ["Деталі", "access"], ["VPN/RDP", "access"], ["Підключення", "access"], ["Подробности", "access"], ["Details", "access"], ["Подключение", "access"],
    ["Контакты", "contacts"], ["Контакти", "contacts"], ["Контакт", "contacts"], ["Contacts", "contacts"], ["Контактное лицо", "contacts"], ["Контактна особа", "contacts"],
  ];
  for (const [header, field] of cases) assert.equal(fieldFor(header), field, header);
  // «Контакты» — тоже из файла по запросу (только в карточке подробностей), в памяти списка их нет.
  assert.deepEqual(["password", "accountPassword", "access", "account", "contacts", "note"].map(isSecret), [true, true, true, false, true, false]);
});

test("«Контакты» — известная колонка: не «лишняя», файл чистый; в записи нет ни контактов, ни пароля учётки, ни «Доступа»", () => {
  const rows = [["Название", "ID", "Контакты", "Учётная запись", "Пароль учётной записи", "Доступ"], ["Касса", "123 456 789", CONTACT, "admin", "Win-1", "строка 1\n\nстрока 2"]];
  for (const [data, kind] of [[F.xlsxRows(rows), "xlsx"], [FILE, "xml"]]) {
    const snap = load(data, kind);
    assert.deepEqual(snap.diagnostics.unrecognizedColumns, [], kind);
    assert.ok(models.isClean(snap.diagnostics), kind);
    noSecrets(snap, kind);
    assert.ok(!JSON.stringify(snap).includes("Win-1"));
  }
  const r = load(F.xlsxRows(rows), "xlsx").records[0];
  assert.equal(r.account, "admin");
  assert.equal(r.hasAccountPassword, true);
  assert.equal(r.accessLines, 2, "пустая строка между блоками не считается");
  assert.ok(!("contacts" in r));
  assert.equal(r.hasContacts, true, "в записи — только признак");
});

// ---------- RDP, VPN, «Другое» ----------

test("RDP/VPN/«Другое»: ID пустой или IP — грузится без жалоб; филиал — отдельная запись в той же группе; метки VPN/RDP — значки", () => {
  const snap = load(FILE, "xml");
  assert.equal(snap.records.length, 5);
  assert.deepEqual(snap.diagnostics.skipped, []);
  assert.deepEqual(snap.diagnostics.duplicates, [], "пустые ID — не дубликаты");
  assert.ok(models.isClean(snap.diagnostics));
  const r = byName(snap.records);
  const branch = r["Вінницька · Філія 2"];
  assert.equal(branch.method, "rdp");
  assert.equal(branch.program, null);
  assert.equal(branch.id, "10.20.0.15", "адрес RDP — как есть");
  assert.equal(models.displayID(branch), "10.20.0.15", "без группировки по три цифры");
  assert.equal(branch.group, "Вінницька");
  assert.ok(models.usesRDP(branch) && models.needsVPN(branch));
  assert.deepEqual(models.labelsOf(branch).map(displayTag), ["Рег", "Фито"], "VPN/RDP — не метки; «рег.» = «Рег», «фіто» = «Фито»");
  assert.equal(branch.accessLines, 4);
  assert.equal(r["Озерна"].method, "other");
  assert.equal(r["Озерна"].id, "");
  assert.equal(models.favoriteKey(r["Озерна"]), "name:Озерна");
  assert.equal(models.favoriteKey(r["Східна"]), "987654321");
  assert.equal(r["Лісова"].method, "vpn");
  assert.ok(models.needsVPN(r["Східна"]), "VPN по метке");
  assert.ok(!models.usesRDP(r["Східна"]));
  assert.equal(r["Північна лабораторія"].account, "Администратор");
  assert.equal(r["Північна лабораторія"].hasAccountPassword, true);
});

test("способы: имена RDP/VPN/«Другое» на ru/uk/en; без способа ID обязателен; два пустых ID — не дубликаты", () => {
  for (const n of ["rdp", "РДП", "Remote Desktop", "mstsc", "Windows App"]) assert.equal(models.parseMethod(n), "rdp", n);
  for (const n of ["VPN", "впн"]) assert.equal(models.parseMethod(n), "vpn", n);
  for (const n of ["Другое", "другие", "Інше", "other", "прочее", "иное", "Телефон", "phone"]) assert.equal(models.parseMethod(n), "other", n);
  assert.equal(models.parseMethod("AnyDesk"), null);
  const rows = [["Название", "ID", "Программа"], ["А", "", "VPN"], ["Б", "", "VPN"], ["В", "", "Другое"], ["Г", "", "AnyDesk"], ["Д", "", ""], ["Е", "srv-1.lan:3390", "RDP"]];
  const snap = load(F.xlsxRows(rows), "xlsx");
  assert.deepEqual(snap.records.map((x) => x.name), ["А", "Б", "В", "Е"]);
  assert.deepEqual(snap.diagnostics.skipped.map((s) => [s.row, s.reason]), [[5, "missingID"], [6, "missingID"]]);
  assert.deepEqual(snap.diagnostics.duplicates, []);
  assert.deepEqual(snap.diagnostics.ambiguousProgramRows, []);
});

test("метки: ключ без регистра, точек и пробелов, і/ї→и, є→е, ґ→г, ё→е; «Рег»/«Фито» показываются единообразно", () => {
  assert.equal(new Set(["Рег", "рег.", "РЕГ", " Рег "].map(tagKey)).size, 1);
  assert.equal(new Set(["Фито", "фито", "Фіто", "ФІТО."].map(tagKey)).size, 1);
  assert.equal(tagKey("Їжа є ґанок Ёлка"), "ижаеганокелка");
  assert.equal(tagKind("фіто"), "phyto");
  assert.equal(tagKind("Рег."), "reg");
  assert.equal(tagKind("Сервер"), "other");
  assert.equal(displayTag("рег."), "Рег");
  assert.equal(displayTag("ЛІМС"), "ЛІМС");
  assert.ok(isBadgeTag("vpn") && isBadgeTag("R.D.P") && !isBadgeTag("Рег"));
  assert.deepEqual(splitTags("Рег, рег., Фіто, фито; Сервер"), ["Рег", "Фіто", "Сервер"]);
});

// ---------- секреты ----------

test("«Доступ» — с переносами и пустыми строками, только по запросу; пароль учётки отдельно от пароля программы; записи без ID — по названию", () => {
  const snap = load(FILE, "xml");
  const r = byName(snap.records);
  assert.equal(text(secretFor("access", r["Вінницька · Філія 2"], FILE, "xml")), ACCESS);
  assert.equal(text(secretFor("accountPassword", r["Північна лабораторія"], FILE, "xml")), "Win-pass-1");
  assert.equal(text(passwordFor(r["Північна лабораторія"], FILE, "xml")), "AD-pass-1", "«Пароль» — пароль AnyDesk");
  assert.equal(text(secretFor("access", r["Лісова"], FILE, "xml")), "Профиль: лес");
  assert.equal(secretFor("accountPassword", r["Лісова"], FILE, "xml"), null);
  assert.equal(secretFor("access", r["Озерна"], FILE, "xml"), null);
  assert.throws(() => secretFor("account", r["Озерна"], FILE, "xml"));
  // Файл поправили: строка записи без ID сдвинулась — находится по названию; чужое название — «записи нет».
  const moved = xml(["<connection><name>Новая</name><id>111222333</id></connection>", ...ROWS]);
  assert.equal(text(secretFor("access", r["Лісова"], moved, "xml")), "Профиль: лес");
  assert.equal(secretFor("access", { ...r["Лісова"], name: "Чужая" }, moved, "xml"), null);
  // В .xlsx — то же; многострочная ячейка сохраняет переносы.
  const rows = [["Название", "ID", "Программа", "Доступ", "Пароль учётной записи"], ["Склад", "", "VPN", "a\n\nb", " пробел "]];
  const x = F.xlsxRows(rows), rec = load(x, "xlsx").records[0];
  assert.equal(text(secretFor("access", rec, x, "xlsx")), "a\n\nb");
  assert.equal(text(secretFor("accountPassword", rec, x, "xlsx")), " пробел ");
});

test("поиск: логин учётки и метки ищутся; «Доступ», пароли и контакты — нет", () => {
  const search = new ConnectionSearch(load(FILE, "xml").records);
  for (const q of ["Demo-77", "WireGuard", "Win-pass", "AD-pass", "050 000", "Иван", "операт"]) assert.deepEqual(search.search(q).records, [], q);
  assert.deepEqual(search.search("lims.admin").records.map((x) => x.name), ["Вінницька · Філія 2"]);
  assert.deepEqual(new Set(search.search("фито").records.map((x) => x.name)), new Set(["Вінницька · Філія 2", "Східна"]));
  assert.deepEqual(search.search("Администратор").records.map((x) => x.name), ["Північна лабораторія"]);
});

// ---------- фильтры и метки ----------

test("фильтры RDP/VPN и строка «МЕТКИ»: AnyDesk/TV не считают RDP/VPN/«Другое»; метки — все выбранные сразу, вместе с фильтром программы", () => {
  const search = new ConnectionSearch(load(FILE, "xml").records);
  const build = (filter, tags = [], query = "") => lists.buildListing({ search, query, filter, defaultProgram: "anyDesk", favorites: [], recents: [], tags });
  const all = build("all");
  assert.deepEqual(all.counts, { all: 5, anyDesk: 1, teamViewer: 1, rdp: 1, vpn: 3 });
  assert.deepEqual(all.tags.map((t) => [t.title, t.count, t.kind]), [["Рег", 4, "reg"], ["Фито", 2, "phyto"], ["Сервер", 1, "other"]]);
  assert.deepEqual(new Set(build("vpn").rows.map((x) => x.record.name)), new Set(["Вінницька · Філія 2", "Лісова", "Східна"]));
  assert.deepEqual(build("rdp").rows.map((x) => x.record.name), ["Вінницька · Філія 2"]);
  assert.deepEqual(build("anyDesk").rows.map((x) => x.record.name), ["Північна лабораторія"]);
  assert.deepEqual(build("all", [tagKey("Рег"), tagKey("Фито")]).rows.map((x) => x.record.name), ["Вінницька · Філія 2"], "все выбранные сразу");
  assert.deepEqual(new Set(build("vpn", [tagKey("фіто")]).rows.map((x) => x.record.name)), new Set(["Вінницька · Філія 2", "Східна"]));
  // Счётчики меток — по записям после поиска и фильтра программы; выбранная метка остаётся и с нулём.
  assert.deepEqual(build("teamViewer").tags.map((t) => [t.title, t.count]), [["Фито", 1]]);
  assert.deepEqual(build("teamViewer", ["рег"]).tags.map((t) => [t.title, t.count]), [["Рег", 0], ["Фито", 1]]);
  assert.deepEqual(build("all", [], "Озерна").tags.map((t) => [t.title, t.count]), [["Рег", 1], ["Сервер", 1]]);
  // Остальные — по частоте, при равенстве — по порядку в файле.
  const many = new ConnectionSearch(load(F.xlsxRows([["Название", "ID", "Теги"], ["a", "111111111", "Б, А"], ["b", "222222222", "А, В"], ["c", "333333333", "Фито"]]), "xlsx").records);
  assert.deepEqual(lists.tagCounts(many.records).map((t) => t.title), ["Фито", "А", "Б", "В"]);
});

test("избранное и недавние для записей без ID — по названию; с ID — по ID", () => {
  const records = load(FILE, "xml").records, r = byName(records);
  const prefs = { favoriteIDs: [], recentIDs: [] };
  lists.toggleFavorite(r["Озерна"], prefs);
  lists.noteConnected(r["Лісова"], prefs);
  lists.noteConnected(r["Східна"], prefs);
  assert.deepEqual(prefs, { favoriteIDs: ["name:Озерна"], recentIDs: ["987654321", "name:Лісова"] });
  assert.ok(lists.isFavorite(r["Озерна"], prefs) && !lists.isFavorite(r["Лісова"], prefs));
  const l = lists.buildListing({ search: new ConnectionSearch(records), query: "", filter: "all", defaultProgram: "anyDesk", favorites: prefs.favoriteIDs, recents: prefs.recentIDs });
  assert.deepEqual(l.sections.slice(0, 2).map((s) => [s.kind, s.records.map((x) => x.name)]), [["favorites", ["Озерна"]], ["recents", ["Східна", "Лісова"]]]);
});

// ---------- RDP: mstsc ----------

test("адрес RDP: только [A-Za-z0-9.-_:[]], не длиннее 255; mstsc — полным путём, аргумент /v:<адрес>", () => {
  for (const h of ["10.20.0.15", " srv-1.example.lan:3390 ", "[fe80::1]:3389", "HOST_1"]) assert.ok(rdp.isValidHost(h), h);
  for (const h of ["", "a b", "10.0.0.1\npassword:s:x", "x;calc", "a&b", "\"x\"", "/v:x", "h".repeat(256), "сервер"]) assert.ok(!rdp.isValidHost(h), JSON.stringify(h));
  assert.deepEqual(rdp.mstscArgs(" 10.20.0.15 "), ["/v:10.20.0.15"]);
  assert.equal(rdp.mstscArgs("x y"), null);
  assert.equal(rdp.mstscPath({ SystemRoot: "D:\\Win" }), "D:\\Win\\System32\\mstsc.exe");
  assert.equal(rdp.rdpHost({ method: "rdp", id: "10.0.0.1" }), "10.0.0.1");
  assert.equal(rdp.rdpHost({ method: "vpn", id: "10.0.0.1" }), "");
  assert.equal(rdp.rdpHost({ method: "rdp", id: "" }), "");
});

const MSTSC = "C:\\Windows\\System32\\mstsc.exe", AD = "C:\\Program Files (x86)\\AnyDesk\\AnyDesk.exe", TV = "C:\\Program Files\\TeamViewer\\TeamViewer.exe";
function rig({ installed = [MSTSC, AD, TV], copyText = () => true } = {}) {
  const spawned = [], states = [], log = [], copied = [];
  const spawn = (file, args, opts) => {
    const child = new EventEmitter(), chunks = [];
    child.stdin = { write: (d, cb) => { chunks.push(Buffer.from(d)); cb?.(); }, end() {}, on() {} };
    child.unref = () => {};
    spawned.push({ file, args, opts, chunks });
    return child;
  };
  const uiaCalls = [];
  const uia = { enter: async (opts, s) => { await opts.afterReady?.(); uiaCalls.push(s ? Buffer.from(s.bytes).toString("utf8") : null); return { state: "entered" }; } };
  const connector = createConnector({ exists: (p) => installed.includes(p), env: { SystemRoot: "C:\\Windows" }, spawn, uia, hud: { show: (s) => states.push(s) }, log: (l) => log.push(l),
    copyText: (t) => { copied.push(t); return copyText(t); } });
  return { connector, spawned, states, log, copied, uiaCalls };
}
const settings = { defaultProgram: "anyDesk", timeoutSeconds: 20, programPaths: {} };

test("Enter на RDP: mstsc /v:<адрес>, без логина и пароля; нет mstsc — только адрес в буфер; VPN, «Другое» и плохой адрес — подробности", async () => {
  const records = byName(load(FILE, "xml").records);
  const store = { password: async () => assert.fail("пароль программы не читается"), secret: async () => assert.fail("секреты не читаются") };
  const r = rig();
  assert.deepEqual(await r.connector.connectRecord(records["Вінницька · Філія 2"], { settings, store }), { ok: true });
  assert.deepEqual(r.spawned.map((s) => [s.file, s.args]), [[MSTSC, ["/v:10.20.0.15"]]]);
  assert.ok(!JSON.stringify(r.spawned[0]).includes("lims.admin"), "логина в команде нет");
  assert.equal(r.states.at(-1).kind, "info", "подключение не подтверждено — не «успех»");
  for (const name of ["Лісова", "Озерна"]) assert.deepEqual(await r.connector.connectRecord(records[name], { settings, store }), { ok: false, error: "details" }, name);
  assert.deepEqual(await r.connector.connectRecord({ ...records["Вінницька · Філія 2"], id: "10.0.0.1 & calc" }, { settings, store }), { ok: false, error: "details" });
  assert.equal(r.spawned.length, 1, "ничего больше не запускалось");
  assert.deepEqual(r.log, ["rdp ok"]);

  const missing = rig({ installed: [] });
  assert.deepEqual(await missing.connector.connectRecord(records["Вінницька · Філія 2"], { settings, store }), { ok: false, error: "notInstalled" });
  assert.deepEqual(missing.copied, ["10.20.0.15"]);
  assert.equal(missing.spawned.length, 0);
  assert.match(missing.states.at(-1).title, /адрес скопирован/);
  assert.equal(missing.states.at(-1).kind, "info");
  assert.ok(missing.log.every((l) => /^rdp (ok|fail)[ A-Za-z=0-9]*$/.test(l)), missing.log.join("|"));
});

test("учётка Windows при подключении: пароль учётки не читается и не уходит в AnyDesk/TeamViewer; пароль программы — только свой", async () => {
  const records = byName(load(FILE, "xml").records);
  const calls = [];
  const store = { password: async (rec) => { calls.push("password"); return new SecretBuffer(text(passwordFor(rec, FILE, "xml")) || ""); },
    secret: async (_rec, field) => { calls.push(field); return null; } };
  // У записи AnyDesk есть и пароль программы, и пароль учётки: в stdin — только пароль программы.
  const r = rig();
  await r.connector.connectRecord(records["Північна лабораторія"], { settings, store });
  assert.deepEqual(calls, ["password"]);
  assert.deepEqual(r.spawned[0].args, ["123456789", "--with-password"]);
  assert.equal(Buffer.concat(r.spawned[0].chunks).toString(), "AD-pass-1\n");
  // Только пароль учётки (пароля программы нет): AnyDesk открывается без пароля, пароль учётки не читается.
  const onlyAccount = { ...records["Північна лабораторія"], hasPassword: false };
  const r2 = rig(); calls.length = 0;
  await r2.connector.connectRecord(onlyAccount, { settings, store });
  assert.deepEqual(calls, []);
  assert.deepEqual(r2.spawned[0].args, ["123456789"]);
  assert.equal(r2.spawned[0].chunks.length, 0);
  // TeamViewer с паролем учётки и без пароля программы — в окно ничего не вводится.
  const tv = { ...records["Східна"], account: "Администратор", hasAccountPassword: true };
  const r3 = rig(); calls.length = 0;
  await r3.connector.connectRecord(tv, { settings, store });
  assert.deepEqual(calls, []);
  assert.deepEqual(r3.uiaCalls, [null]);
  for (const x of [r, r2, r3]) assert.ok(!JSON.stringify([x.states, x.log]).match(/Win-pass|Администратор|lims/), "в тостах и журнале нет логина и пароля учётки");
});

// ---------- буфер обмена ----------

function fakeClipboard() {
  const cb = { text: "", writes: 0, clears: 0, writeText(t) { this.text = t; this.writes++; }, readText() { return this.text; }, clear() { this.text = ""; this.clears++; } };
  return cb;
}
function fakeTimers() {
  const timers = [];
  return { timers, setTimer: (fn, ms) => { const t = { fn, ms }; timers.push(t); return t; }, clearTimer: (t) => { const i = timers.indexOf(t); if (i >= 0) timers.splice(i, 1); }, fire() { for (const t of timers.splice(0)) t.fn(); } };
}

test("секрет в буфер: через 30 с очищается, если там всё ещё он; скопированное после — не трогается; секрет затирает вызывающий", async () => {
  const cb = fakeClipboard(), t = fakeTimers();
  const sc = createSecretClipboard({ clipboard: cb, setTimer: t.setTimer, clearTimer: t.clearTimer });
  const s = new SecretBuffer("Win-pass-1");
  assert.equal(await sc.copy(s), true);
  assert.equal(cb.text, "Win-pass-1");
  assert.equal(t.timers[0].ms, 30_000);
  t.fire();
  assert.equal(cb.text, "");
  assert.equal(cb.clears, 1);

  await sc.copy(new SecretBuffer("Win-pass-2"));
  cb.text = "пользователь скопировал своё";
  t.fire();
  assert.equal(cb.text, "пользователь скопировал своё", "чужое не стирается");

  await sc.copy(new SecretBuffer("Win-pass-3"));
  assert.equal(sc.pending, 1);
  sc.flush();   // выход из приложения
  assert.equal(cb.text, "");
  assert.equal(sc.pending, 0);
  assert.equal(t.timers.length, 0);
  assert.equal(await sc.copy(new SecretBuffer("")), false, "пустое не копируется");
  assert.equal(await createSecretClipboard({}).copy(new SecretBuffer("x")), false, "без буфера — false");
});

// ---------- окно: сервис и IPC ----------

function fakeElectron() {
  const handles = new Map(), listeners = new Map(), windows = [], trays = [], menus = [];
  class BrowserWindow {
    constructor(opts) { this.opts = opts; this.sent = []; this.destroyed = false; windows.push(this);
      this.webContents = { send: (...a) => this.sent.push(a), on() {}, setWindowOpenHandler() {} }; }
    loadFile(file, o) { this.file = path.basename(file); this.hash = o?.hash; }
    on() {} isDestroyed() { return this.destroyed; } isMinimized() { return false; }
    show() {} hide() {} focus() {} restore() {} setBounds() {}
  }
  class Tray { constructor() { trays.push(this); } setToolTip() {} on() {} setContextMenu(m) { this.menu = m; } destroy() {} }
  return { handles, listeners, windows, trays, menus,
    electron: { app: { getPath: () => os.tmpdir() }, BrowserWindow, Tray,
      Menu: { buildFromTemplate: (t) => { const m = { items: t, popup() { menus.push(t); } }; return m; }, getApplicationMenu: () => null, setApplicationMenu() {} }, MenuItem: class {},
      globalShortcut: { register: () => true, unregister() {}, unregisterAll() {} },
      ipcMain: { handle: (n, fn) => handles.set(n, fn), on: (n, fn) => listeners.set(n, fn) },
      shell: { openPath() {}, openExternal() {} }, dialog: {}, nativeImage: { createFromPath: () => ({ resize: () => ({}) }), createEmpty: () => ({}) },
      screen: { getCursorScreenPoint: () => ({ x: 0, y: 0 }), getDisplayNearestPoint: () => ({ workArea: { x: 0, y: 0, width: 1920, height: 1040 } }) } } };
}
async function app({ file = FILE, ext = "xml", extra = {} } = {}) {
  const dir = tmp(), list = path.join(dir, `list.${ext}`);
  fs.writeFileSync(list, file);
  fs.writeFileSync(path.join(dir, "remote-connections.json"), JSON.stringify({ file: list }));
  const fake = fakeElectron(), huds = [], log = [], cb = fakeClipboard(), copied = [], rdpOpened = [];
  const connector = { MESSAGES: { gone: () => ({ title: "gone" }) }, installed: () => true, hudAction() {},
    connectRecord: async (rec) => (rec.method && !(rec.method === "rdp" && rdp.isValidHost(rec.id)) ? { ok: false, error: "details" } : { ok: true }),
    openRDP: async (rec) => { rdpOpened.push({ method: rec.method, id: rec.id }); return { ok: true }; } };
  const rc = init(fake.electron, { userData: dir, timing: { debounceMs: 20, retryMs: 20, pollMs: 30 }, connector, hud: { show: (s) => huds.push(s) }, log: (l) => log.push(l),
    clipboard: cb, copyText: (t) => { copied.push(t); return true; }, ...extra });
  for (let i = 0; i < 200 && rc.store.state.status !== "ready"; i++) await new Promise((r) => setTimeout(r, 10));
  const trust = () => { rc.openWindow(); return { sender: fake.windows.find((w) => w.file === "remote.html" && !w.hash).webContents }; };
  const call = (name, ...args) => fake.handles.get(name)(trust(), ...args);
  const keyOf = (name) => rc.service.records().find((r) => r.name === name);
  const key = (name) => { const r = keyOf(name); return `${r.sourceRow}:${r.id}`; };
  return { fake, rc, dir, list, huds, log, cb, copied, rdpOpened, call, key };
}

test("вид окна: строка с метками, значками, логином, числом строк «Доступа»; фильтры и метки через IPC; секретов и контактов в ответах нет", async () => {
  const a = await app();
  const v = await a.call("rc:view", { query: "", filter: "all", tags: [] });
  noSecrets(v, "view");
  assert.deepEqual(v.counts, { all: 5, anyDesk: 1, teamViewer: 1, rdp: 1, vpn: 3 });
  assert.deepEqual(v.tags.map((t) => t.title), ["Рег", "Фито", "Сервер"]);
  assert.equal(v.diagnostics.vpn, 3);
  assert.equal(v.diagnostics.rdp, 1);
  assert.equal(v.canView, true);
  const rows = Object.fromEntries(v.sections.flatMap((s) => s.records).map((r) => [r.name, r]));
  const b = rows["Вінницька · Філія 2"];
  assert.deepEqual([b.method, b.methodTitle, b.program, b.id, b.rdpHost, b.needsVPN, b.usesRDP, b.account, b.hasAccountPassword, b.accessLines],
    ["rdp", "RDP", null, "10.20.0.15", "10.20.0.15", true, true, "lims.admin", true, 4]);
  assert.deepEqual(b.labels, [{ title: "Рег", kind: "reg" }, { title: "Фито", kind: "phyto" }]);
  assert.equal(b.programChoice, "RDP");
  assert.equal(rows["Озерна"].id, "", "без ID — окно пишет «без ID»");
  assert.equal(rows["Озерна"].methodTitle, "Другое");
  assert.equal(rows["Північна лабораторія"].programTitle, "AnyDesk");
  assert.equal(rows["Північна лабораторія"].dim, false);
  const vpn = await a.call("rc:view", { query: "", filter: "vpn", tags: ["фито"] });
  assert.deepEqual(new Set(vpn.sections.flatMap((s) => s.records).map((r) => r.name)), new Set(["Вінницька · Філія 2", "Східна"]));
  const login = await a.call("rc:view", { query: "lims", filter: "nonsense" });
  assert.deepEqual(login.sections[0].records[0].accountMarks, [{ start: 0, end: 4 }]);
  const note = await a.call("rc:view", { query: "телефон" });
  assert.deepEqual(note.sections[0].records.map((r) => r.noteLine), ["Только по телефону"]);
  a.rc.dispose();
});

test("подробности: запись по ключу; «Показать» — «Доступ» из файла с пустыми строками; копия пароля учётки и «Доступа» — в буфер на 30 с; в журнале — только код поля", async () => {
  const a = await app();
  const details = await a.call("rc:details", a.key("Вінницька · Філія 2"));
  assert.equal(details.name, "Вінницька · Філія 2");
  noSecrets(details, "details");
  assert.deepEqual(await a.call("rc:revealAccess", a.key("Вінницька · Філія 2")), { ok: true, text: ACCESS });
  assert.deepEqual(await a.call("rc:revealAccess", a.key("Озерна")), { ok: false });
  assert.deepEqual(await a.call("rc:copySecret", { key: a.key("Вінницька · Філія 2"), field: "accountPassword" }), { ok: true });
  assert.equal(a.cb.text, "Win-pass-2");
  assert.match(a.huds.at(-1).title, /Пароль учётки скопирован/);
  assert.match(a.huds.at(-1).detail, /30 с/);
  assert.deepEqual(await a.call("rc:copySecret", { key: a.key("Лісова"), field: "access" }), { ok: true });
  assert.equal(a.cb.text, "Профиль: лес");
  // Пароль программы так не достать.
  assert.deepEqual(await a.call("rc:copySecret", { key: a.key("Північна лабораторія"), field: "password" }), { ok: false, error: "field" });
  assert.equal(a.cb.text, "Профиль: лес");
  // Нет пароля учётки — честно «не удалось прочитать».
  assert.deepEqual(await a.call("rc:copySecret", { key: a.key("Озерна"), field: "accountPassword" }), { ok: false, error: "unavailable" });
  assert.deepEqual(a.log, ["copy ok field=accountPassword", "copy ok field=access", "copy fail field=accountPassword"]);
  a.log.length = 0;
  noSecrets([a.huds, a.log], "тосты и журнал");
  // Адрес RDP — обычной копией (не секрет).
  assert.deepEqual(await a.call("rc:copyAddress", { key: a.key("Вінницька · Філія 2") }), { ok: true });
  assert.deepEqual(a.copied, ["10.20.0.15"]);
  // Выход из приложения: секрет не остаётся в буфере.
  a.rc.dispose();
  assert.equal(a.cb.text, "");
});

test("меню строки: «Скопировать пароль учётки» — только если он есть; VPN без «Подключиться»; RDP — «Открыть удалённый рабочий стол»; .xlsx — «Изменить…» (просмотр)", async () => {
  const a = await app();
  const labels = (name) => a.rc.rowMenuTemplate(a.key(name), null).map((i) => i.label || "—");
  assert.deepEqual(labels("Північна лабораторія"), ["Подключиться", "Открыть без пароля", "В избранное", "Подробности", "Скопировать пароль учётки", "—", "Изменить…"]);
  assert.deepEqual(labels("Лісова"), ["В избранное", "Подробности", "—", "Изменить…"]);
  assert.deepEqual(labels("Вінницька · Філія 2"), ["Открыть удалённый рабочий стол", "В избранное", "Подробности", "Скопировать пароль учётки", "Скопировать адрес", "—", "Изменить…"]);
  // Пункт меню копирует пароль учётки; «Подробности» уходят окну.
  const sent = [];
  const items = a.rc.rowMenuTemplate(a.key("Північна лабораторія"), { send: (...m) => sent.push(m) });
  await items.find((i) => i.label === "Скопировать пароль учётки").click();
  assert.equal(a.cb.text, "Win-pass-1");
  items.find((i) => i.label === "Подробности").click();
  assert.deepEqual(sent, [["rc:menu", { action: "details", key: a.key("Північна лабораторія") }]]);
  assert.equal(await a.call("rc:rowMenu", a.key("Лісова")), true);
  assert.equal(a.fake.menus.length, 1);
  assert.equal(await a.call("rc:rowMenu", "999:x"), false);
  a.rc.dispose();
  // .xlsx: тот же пункт — карточка только для просмотра (canEdit false, canView true); запись в .xlsx — отказ.
  const rows = [["Название", "ID", "Программа", "Учётная запись"], ["Касса", "123456789", "AnyDesk", "admin"]];
  const x = await app({ file: F.xlsxRows(rows), ext: "xlsx" });
  const v = await x.call("rc:view", {});
  assert.equal(v.canEdit, false);
  assert.equal(v.canView, true);
  assert.ok(x.rc.rowMenuTemplate(x.key("Касса"), null).some((i) => i.label === "Изменить…"));
  const before = fs.readFileSync(x.list);
  assert.deepEqual(await x.call("rc:edit", { action: "update", payload: { key: x.key("Касса"), fields: { name: "Новое", id: "123456789" } } }), { ok: false, error: "xlsxReadOnly" });
  assert.equal(fs.readFileSync(x.list).compare(before), 0, "книга не изменилась");
  x.rc.dispose();
});

test("трей: запись VPN — подробности в окне списка; RDP — mstsc; IPC новых вызовов — только от окон модуля", async () => {
  const a = await app();
  assert.deepEqual(await a.rc.connect(a.key("Лісова"), false, true), { ok: false, error: "details" });
  const win = a.fake.windows.find((w) => w.file === "remote.html" && !w.hash);
  assert.ok(win.sent.some(([c]) => c === "rc:details"));
  assert.equal(await a.call("rc:pendingDetails"), a.key("Лісова"));
  assert.equal(await a.call("rc:pendingDetails"), null, "ключ забирается один раз");
  assert.deepEqual(await a.call("rc:openRDP", { key: a.key("Вінницька · Філія 2") }), { ok: true });
  assert.deepEqual(a.rc.settings.recentIDs, ["10.20.0.15"], "открытый RDP — в «Недавних»");
  const stranger = { sender: { id: 99 } };
  for (const [name, arg] of [["rc:details", a.key("Лісова")], ["rc:revealAccess", a.key("Лісова")], ["rc:copySecret", { key: a.key("Лісова"), field: "access" }],
    ["rc:copyAddress", { key: a.key("Вінницька · Філія 2") }], ["rc:openRDP", { key: a.key("Вінницька · Філія 2") }], ["rc:rowMenu", a.key("Лісова")], ["rc:pendingDetails"],
    ["rc:cardInfo", a.key("Північна лабораторія")], ["rc:copyPhone", "050 000 00 00"], ["rc:copySecret", { key: a.key("Вінницька · Філія 2"), field: "vpnSecret" }], ["rc:showFolder"]]) {
    const r = await a.fake.handles.get(name)(stranger, arg);
    assert.ok(r == null || r === false || r.ok === false, `${name}: ${JSON.stringify(r)}`);
  }
  assert.equal(a.cb.writes, 0, "чужому окну ничего не скопировано");
  a.rc.dispose();
});

// ---------- правка XML ----------

test("правка XML: логин и пароль учётки пишутся; «Контакты» и «Доступ» — байт в байт; запись VPN без ID; без программы ID обязателен", () => {
  const dir = tmp(), file = path.join(dir, "list.xml");
  fs.writeFileSync(file, FILE);
  const recs = () => load(fs.readFileSync(file), "xml").records;
  const north = recs()[0];
  assert.deepEqual(editor.apply(file, "update", { record: north, fields: { name: north.name, id: "123 456 789", group: north.group, tags: "Рег", note: "", program: "AnyDesk", account: "Оператор", accountPassword: "Новый-Win-2" } }), { ok: true });
  const out = fs.readFileSync(file, "utf8");
  assert.ok(out.includes(`<contacts>${esc(CONTACT)}</contacts>`), "контакты — как были");
  assert.ok(out.includes(`<access>${esc(ACCESS)}</access>`), "«Доступ» соседней записи — байт в байт");
  assert.ok(out.includes("<password>AD-pass-1</password>"), "пароль программы не тронут");
  const again = recs()[0];
  assert.equal(again.account, "Оператор");
  assert.equal(text(secretFor("accountPassword", again, fs.readFileSync(file), "xml")), "Новый-Win-2");
  // Пароль учётки не передан — не меняется; "" — убирается.
  assert.deepEqual(editor.apply(file, "update", { record: again, fields: { name: again.name, id: again.id, group: again.group, tags: "Рег", program: "AnyDesk", account: "Оператор" } }), { ok: true });
  assert.equal(text(secretFor("accountPassword", recs()[0], fs.readFileSync(file), "xml")), "Новый-Win-2");
  assert.deepEqual(editor.apply(file, "update", { record: recs()[0], fields: { name: again.name, id: again.id, group: again.group, tags: "Рег", program: "AnyDesk", account: "Оператор", accountPassword: "" } }), { ok: true });
  assert.equal(recs()[0].hasAccountPassword, false);
  // RDP-запись с адресом: правка заметки не трогает адрес.
  const branch = recs().find((r) => r.method === "rdp");
  assert.deepEqual(editor.apply(file, "update", { record: branch, fields: { name: branch.name, id: branch.id, group: branch.group, tags: branch.tags.join(", "), note: "после VPN", program: "RDP", account: branch.account } }), { ok: true });
  const b2 = recs().find((r) => r.method === "rdp");
  assert.equal(b2.id, "10.20.0.15");
  assert.equal(b2.note, "после VPN");
  assert.ok(fs.readFileSync(file, "utf8").includes(`<access>${esc(ACCESS)}</access>`));
  // Новая запись VPN без ID — допустима.
  assert.deepEqual(editor.apply(file, "add", { fields: { name: "Філія 3", group: "Вінницька", tags: "Рег, VPN", program: "VPN" } }), { ok: true });
  const last = recs().at(-1);
  assert.deepEqual([last.name, last.method, last.id], ["Філія 3", "vpn", ""]);
  assert.deepEqual(editor.validate({ name: "x" }), { error: "missingID" });
  assert.equal(editor.validate({ name: "x", program: "Телефон" }).value.program, "Другое");
});

test("шаблон: колонки учётки, «Доступа» и «Контактов» распознаются, файл чистый", () => {
  const snap = load(templates.templateBuffer("xlsx"), "xlsx");
  assert.deepEqual(snap.diagnostics.unrecognizedColumns, []);
  assert.ok(models.isClean(snap.diagnostics));
  for (const f of ["account", "accountPassword", "access", "contacts"]) assert.ok(snap.diagnostics.columns.some((c) => c.field === f), f);
  assert.ok(models.isClean(load(templates.templateBuffer("xml"), "xml").diagnostics));
});

test("окно: метки и «Доступ» только через textContent; пароль учётки окну не отдаётся; «Доступ» убирается при уходе с подробностей", () => {
  const ui = path.join(__dirname, "..", "..", "remote", "ui");
  const js = fs.readFileSync(path.join(ui, "remote.js"), "utf8"), preload = fs.readFileSync(path.join(ui, "preload.js"), "utf8");
  assert.equal((js.match(/innerHTML/g) || []).length, 1);
  assert.ok(!/revealAccess\([^)]*accountPassword/.test(js) && !/rc:revealAccount|revealPassword/.test(js + preload), "пароль учётки на экран не выводится");
  assert.match(js, /function closeDetails\(\)[\s\S]{0,200}detailsBox"\)\?\.remove\(\)/, "при уходе с подробностей их узел (и «Доступ») удаляется");
  assert.match(js, /visibilitychange/, "окно скрыто — «Доступ» убирается");
  assert.match(js, /"без ID"/);
  assert.match(js, /могут быть пароли/);
});

// ---------- последние правки: «Как подключиться», «Контакты», палитра; секреты — мимо журнала буфера (W2-5) ----------
const access = require("../../remote/access");
const DEMO_KEY = "QUJDREVGR0g=";
const DEMO_ACCESS = `VPN WireGuard — сервер: vpn.demo.invalid:51820 · логин: demo-user · ключ: ${DEMO_KEY}\nRDP — IP: 192.0.2.10 · порт: 3390 · Login: demo-admin`;
const DEMO_CONTACTS = "Ольга (бухгалтерия) +38 (044) 000-00-00\nДежурный: 067 000 11 22, каб. 12";
const DEMO_FILE = xml([...ROWS,
  `<connection><name>Демо-лаборатория</name><id>111222333</id><tags>Рег, VPN</tags><access>${esc(DEMO_ACCESS)}</access><contacts>${esc(DEMO_CONTACTS)}</contacts><app>AnyDesk</app></connection>`]);
const DEMO_SECRETS = [DEMO_KEY, "Ольга", "000-00-00", "067 000", "Дежурный"];

test("«Как подключиться»: тип VPN по тексту, сервер, логин, ключ (с «=» в конце); RDP — адрес с портом и логин; не разобралось — строки как есть", () => {
  const kinds = { "VPN WireGuard 1.2.3.4": "WireGuard", "pptp-vpn: 1.2.3.4": "PPTP", "L2TP/IPsec 1.2.3.4": "L2TP", "FortiClient · сервер forti.demo.invalid": "FortiClient", "OpenVPN профиль demo.ovpn": "OpenVPN", "VPN: 1.2.3.4": null };
  for (const [line, kind] of Object.entries(kinds)) assert.equal(access.parseAccess(line).vpn.kind, kind, line);
  const info = access.parseAccess(DEMO_ACCESS);
  assert.deepEqual({ ...info.vpn, lines: undefined }, { kind: "WireGuard", server: "vpn.demo.invalid:51820", login: "demo-user", secret: DEMO_KEY, lines: undefined });
  assert.deepEqual({ ...info.rdp, lines: undefined }, { address: "192.0.2.10:3390", login: "demo-admin", lines: undefined });
  assert.deepEqual(access.parseAccess("PPTP 192.0.2.7 логин demo пароль p@ss").vpn.secret, "p@ss");
  // Окну — без секрета; адрес RDP из «Доступа» помечен fromAccess (окно его не передаёт обратно — файл читается заново).
  const howto = access.howToConnect({ method: null, id: "111222333", account: "" }, info, { needsVPN: true });
  assert.deepEqual(howto.vpn, { kind: "WireGuard", server: "vpn.demo.invalid:51820", login: "demo-user", hasSecret: true, lines: [] });
  assert.deepEqual(howto.rdp, { address: "192.0.2.10:3390", login: "demo-admin", canOpen: true, fromAccess: true, lines: [] });
  assert.ok(!JSON.stringify(howto).includes(DEMO_KEY));
  // Запись RDP: адрес — её ID, логин — учётка записи.
  const own = access.howToConnect({ method: "rdp", id: "10.20.0.15", account: "lims.admin" }, access.parseAccess(ACCESS), { needsVPN: true, usesRDP: true });
  assert.deepEqual(own.rdp, { address: "10.20.0.15", login: "lims.admin", canOpen: true, fromAccess: false, lines: [] });
  assert.deepEqual(own.vpn, { kind: "WireGuard", server: null, login: null, hasSecret: false, lines: ["VPN (WireGuard) | профиль Выдуманный-1"] }, "не разобралось — строка как есть");
  const raw = access.howToConnect({ method: null, id: "1", account: "" }, access.parseAccess("Подключение через VPN — спросить у админа\nRDP — по запросу"), {});
  assert.deepEqual([raw.vpn.lines, raw.rdp.lines, raw.rdp.address], [["Подключение через VPN — спросить у админа"], ["RDP — по запросу"], null]);
  assert.deepEqual(access.howToConnect({ method: "vpn", id: "", account: "" }, null, { needsVPN: true }).vpn, { kind: null, server: null, login: null, hasSecret: false, lines: [] });
  assert.equal(access.howToConnect({ method: null, id: "1", account: "" }, null, {}).rdp, null, "нет ни метки, ни строк RDP — блока RDP нет");
});

test("телефоны в «Контактах»: цифры с + ( ) - и пробелами, не меньше 7 цифр; перенос строки телефон не продолжает", () => {
  assert.deepEqual(access.findPhones(DEMO_CONTACTS), ["+38 (044) 000-00-00", "067 000 11 22"]);
  assert.deepEqual(access.findPhones("Иван, 050 000 00 00"), ["050 000 00 00"]);
  assert.deepEqual(access.findPhones("каб. 12, тел. 12-34, 23.10.2026"), [], "короткие номера и даты — не телефоны");
  assert.deepEqual(access.findPhones("123\n4567"), []);
  for (const ok of ["+38 (044) 000-00-00", "0670001122"]) assert.ok(access.isPhone(ok), ok);
  for (const bad of ["12-34", "067 000 11 22; calc", "+38 (044) <b>", "1".repeat(25)]) assert.ok(!access.isPhone(bad), bad);
});

test("карточка: «Как подключиться» и «Контакты» — из файла по запросу; ключа VPN в ответе нет; контактов нет в строке, поиске, подробностях и журнале", async () => {
  const a = await app({ file: DEMO_FILE });
  const key = a.key("Демо-лаборатория");
  const card = await a.call("rc:cardInfo", key);
  assert.equal(card.ok, true);
  assert.deepEqual(card.howto.vpn, { kind: "WireGuard", server: "vpn.demo.invalid:51820", login: "demo-user", hasSecret: true, lines: [] });
  assert.deepEqual(card.howto.rdp, { address: "192.0.2.10:3390", login: "demo-admin", canOpen: true, fromAccess: true, lines: [] });
  assert.deepEqual(card.contacts, { text: DEMO_CONTACTS, phones: ["+38 (044) 000-00-00", "067 000 11 22"] });
  assert.ok(!JSON.stringify(card).includes(DEMO_KEY), "пароль или ключ VPN окну не уходит");
  // Без «Доступа» и «Контактов» — пусто; запись RDP — адрес из ID.
  const plain = await a.call("rc:cardInfo", a.key("Східна"));
  assert.deepEqual([plain.contacts, plain.howto.rdp], [null, null]);
  assert.equal(plain.howto.vpn.hasSecret, false);
  assert.equal((await a.call("rc:cardInfo", a.key("Вінницька · Філія 2"))).howto.rdp.address, "10.20.0.15");
  assert.equal((await a.call("rc:cardInfo", a.key("Північна лабораторія"))).contacts.text, CONTACT);
  assert.deepEqual(await a.call("rc:cardInfo", "999:x"), { ok: false });
  // Строка, подробности (rc:details) и поиск контактов не знают.
  const all = await a.call("rc:view", { query: "" });
  const row = all.sections.flatMap((s) => s.records).find((r) => r.name === "Демо-лаборатория");
  assert.equal(row.hasContacts, true);
  for (const value of [all, await a.call("rc:details", key)]) for (const x of DEMO_SECRETS) assert.ok(!JSON.stringify(value).includes(x), x);
  for (const q of ["Ольга", "067", "бухгалтерия", "Дежурный", "demo-user", "vpn.demo"]) {
    const v = await a.call("rc:view", { query: q });
    assert.ok(!v.sections.flatMap((s) => s.records).some((r) => r.name === "Демо-лаборатория"), `поиск «${q}» не по «Контактам»/«Доступу»`);
  }
  assert.deepEqual(a.log, [], "чтение карточки в журнал не пишется");
  a.rc.dispose();
});

test("RW-1: неразобранные строки «Как подключиться» — пароли и ключи под маской ещё в основном процессе; в окне — по «Показать»", async () => {
  const RAW_ACCESS = "RDP — сервер srv01 · логин: admin · пароль: Qw3rty-выдумка\nL2TP VPN · L2tpPsk=Demo-Psk-1 · Password: Demo Pass 2 | профиль у админа";
  const masked = access.parseAccess(RAW_ACCESS);
  assert.deepEqual(masked.rdp.lines, ["RDP — сервер srv01 · логин: admin · пароль: ••••••"]);
  assert.equal(masked.vpn.secret, "Demo-Psk-1", "для «Скопировать» значение берётся из исходной строки");
  assert.deepEqual(masked.vpn.lines, ["L2TP VPN · L2tpPsk=•••••• · Password: •••••• | профиль у админа"]);
  const cases = {
    "VPN pass Demo-3": "VPN pass ••••••", "VPN, пароля: Demo-4": "VPN, пароля: ••••••", "VPN WireGuard key = QUJD=": "VPN WireGuard key = ••••••",
    "VPN PSK: Demo-5; сервер vpn.demo.invalid": "VPN PSK: ••••••; сервер vpn.demo.invalid", "VPN pre-shared key — Demo-6": "VPN pre-shared key — ••••••",
    "RDP pwd:Demo-7": "RDP pwd:••••••", "RDP secret Demo-8 · порт 3389": "RDP secret •••••• · порт 3389", "RDP — пароль:": "RDP — пароль:",
    "VPN Passport office · keyboard US": "VPN Passport office · keyboard US",
  };
  for (const [line, want] of Object.entries(cases)) assert.equal(access.maskSecrets(line), want, line);
  // Через IPC: в ответе окну ни пароля RDP, ни PSK, ни пароля VPN.
  const a = await app({ file: xml([...ROWS, `<connection><name>Без адреса</name><id>111222334</id><tags>VPN, RDP</tags><access>${esc(RAW_ACCESS)}</access><app>AnyDesk</app></connection>`]) });
  const card = await a.call("rc:cardInfo", a.key("Без адреса"));
  assert.equal(card.howto.rdp.address, null);
  assert.deepEqual(card.howto.rdp.lines, masked.rdp.lines);
  for (const x of ["Qw3rty", "Demo-Psk-1", "Demo Pass 2"]) assert.ok(!JSON.stringify(card).includes(x), x);
  a.rc.dispose();
  // Окно: строки — только после «Показать», до того размытые полосы и «могут быть пароли».
  const js = fs.readFileSync(path.join(__dirname, "..", "..", "remote", "ui", "remote.js"), "utf8");
  const raw = js.slice(js.indexOf("function rawLines"), js.indexOf("function howToCard"));
  assert.match(raw, /let shown = false;/);
  assert.match(raw, /if \(shown\) \{\s*pane\.append\(el\("pre", "rawlines"/);
  assert.match(raw, /могут быть пароли/);
  assert.match(raw, /"Показать"/);
});

test("W2-5: пароль/ключ VPN, пароль учётки и «Доступ» — в буфер через помощник мимо журнала Win+V и облака; не вышло — ничего не скопировано", async () => {
  const concealed = [];
  let works = true;
  const writeConcealed = async (secret) => { concealed.push(Buffer.from(secret.bytes).toString("utf8")); return works; };
  const a = await app({ file: DEMO_FILE, extra: { writeConcealed } });
  const key = a.key("Демо-лаборатория");
  assert.deepEqual(await a.call("rc:copySecret", { key, field: "vpnSecret" }), { ok: true });
  assert.deepEqual(concealed, [DEMO_KEY], "ключ целиком, с «=» в конце");
  assert.equal(a.cb.writes, 0, "обычным writeText секрет не пишется");
  assert.equal(a.huds.at(-1).title, "Пароль VPN скопирован");
  assert.match(a.huds.at(-1).detail, /30 с/);
  assert.deepEqual(await a.call("rc:copySecret", { key: a.key("Вінницька · Філія 2"), field: "accountPassword" }), { ok: true });
  assert.equal(concealed.at(-1), "Win-pass-2");
  // У записи без ключа VPN — честно «не удалось».
  assert.deepEqual(await a.call("rc:copySecret", { key: a.key("Вінницька · Філія 2"), field: "vpnSecret" }), { ok: false, error: "unavailable" });
  works = false;
  assert.deepEqual(await a.call("rc:copySecret", { key, field: "access" }), { ok: false });
  assert.equal(a.cb.writes, 0, "помощник не справился — секрет не уходит в буфер обычным текстом");
  assert.equal(a.huds.at(-1).kind, "warning");
  assert.deepEqual(a.log, ["copy ok field=vpnSecret", "copy ok field=accountPassword", "copy fail field=vpnSecret", "copy fail field=access"]);
  for (const x of [...DEMO_SECRETS, "Win-pass-2"]) assert.ok(!JSON.stringify([a.huds, a.log]).includes(x), x);
  a.rc.dispose();
});

test("телефон — «Скопировать» (только строка вида телефона); RDP из «Доступа» — адрес берётся из файла, не из окна", async () => {
  const a = await app({ file: DEMO_FILE });
  const key = a.key("Демо-лаборатория");
  assert.deepEqual(await a.call("rc:copyPhone", "+38 (044) 000-00-00"), { ok: true });
  assert.deepEqual(await a.call("rc:copyPhone", "calc.exe & 0670001122"), { ok: false, error: "phone" });
  assert.deepEqual(a.copied, ["+38 (044) 000-00-00"]);
  assert.equal(a.huds.at(-1).title, "Телефон скопирован");
  assert.deepEqual(await a.call("rc:openRDP", { key, fromAccess: true }), { ok: true });
  assert.deepEqual(a.rdpOpened, [{ method: "rdp", id: "192.0.2.10:3390" }]);
  assert.deepEqual(await a.call("rc:copyAddress", { key, fromAccess: true }), { ok: true });
  assert.equal(a.copied.at(-1), "192.0.2.10:3390");
  // Без строки RDP в «Доступе» — подробности, ничего не открыто.
  assert.deepEqual(await a.call("rc:openRDP", { key: a.key("Лісова"), fromAccess: true }), { ok: false, error: "details" });
  assert.equal(a.rdpOpened.length, 1);
  assert.deepEqual(a.log, ["copy ok field=phone", "copy ok field=address"], "в журнале только коды");
  a.rc.dispose();
});

test("палитра: внизу только «Обновить» (↻); Excel, папка, «Добавить», настройки и «Загружено N · …» — в окне списка; контакты — только в карточке", () => {
  const ui = path.join(__dirname, "..", "..", "remote", "ui");
  const js = fs.readFileSync(path.join(ui, "remote.js"), "utf8"), html = fs.readFileSync(path.join(ui, "remote.html"), "utf8");
  for (const id of ["openFile", "folderBtn", "reload", "addBtn", "settingsBtn", "summary"]) assert.match(html, new RegExp(`id="${id}"`), id);
  assert.match(html, /id="reload"[^>]*aria-label="Обновить">↻</);
  assert.match(js, /if \(palette\) \{ \$\("hints"\)\.hidden = false; for \(const id of \["openFile", "folderBtn", "addBtn", "settingsBtn", "summary"\]\) \$\(id\)\.hidden = true; \}/);
  assert.ok(!/\$\("bar"\)\.hidden = true/.test(js), "панель палитры не прячется целиком — на ней «Обновить»");
  assert.match(js, /function renderSummary\(\) \{[^}]*if \(palette\) \{ s\.textContent = ""; return; \}/);
  assert.match(js, /\$\("addBtn"\)\.hidden = palette \|\|/);
  assert.match(js, /\$\("folderBtn"\)\.onclick = \(\) => window\.rc\.showFolder\(\)/);
  const row = js.slice(js.indexOf("function rowElement"), js.indexOf("function fitAllLabels"));
  assert.ok(!/contacts|phone/i.test(row), "в строке списка контактов нет");
  assert.ok(js.indexOf("contactsCard(currentCard.contacts)") > js.indexOf("async function renderDetails"));
  // Пароль/ключ VPN — только точки и «Скопировать» (vpnSecret копирует основной процесс).
  assert.match(js, /window\.rc\.copySecret\(r\.key, "vpnSecret"\)/);
  assert.ok(!/howto\.vpn\.secret|vpn\.secret/.test(js));
});
