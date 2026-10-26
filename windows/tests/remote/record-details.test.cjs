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

test("фильтр — только программа: «Другое» вместо RDP/VPN (RDP, VPN, «Другое»); строка «МЕТКИ»: все выбранные сразу, вместе с фильтром программы", () => {
  const search = new ConnectionSearch(load(FILE, "xml").records);
  const build = (filter, tags = [], query = "") => lists.buildListing({ search, query, filter, defaultProgram: "anyDesk", favorites: [], recents: [], tags });
  const all = build("all");
  assert.deepEqual(all.counts, { all: 5, anyDesk: 1, teamViewer: 1, other: 3 });
  assert.deepEqual(lists.FILTERS, ["all", "anyDesk", "teamViewer", "other"], "чипов RDP и VPN больше нет");
  assert.deepEqual(all.tags.map((t) => [t.title, t.count, t.kind]), [["Рег", 4, "reg"], ["Фито", 2, "phyto"], ["Сервер", 1, "other"]]);
  assert.deepEqual(new Set(build("other").rows.map((x) => x.record.name)), new Set(["Вінницька · Філія 2", "Озерна", "Лісова"]));
  assert.deepEqual(build("teamViewer").rows.map((x) => [x.record.name, models.needsVPN(x.record)]), [["Східна", true]], "TeamViewer с меткой VPN — в TeamViewer, значок остаётся");
  assert.deepEqual(build("anyDesk").rows.map((x) => x.record.name), ["Північна лабораторія"]);
  assert.deepEqual(build("all", [tagKey("Рег"), tagKey("Фито")]).rows.map((x) => x.record.name), ["Вінницька · Філія 2"], "все выбранные сразу");
  assert.deepEqual(build("other", [tagKey("фіто")]).rows.map((x) => x.record.name), ["Вінницька · Філія 2"]);
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
  const cb = { text: "", writes: 0, clears: 0, concealed: 0, writeText(t) { this.text = t; this.writes++; }, readText() { return this.text; }, clear() { this.text = ""; this.clears++; } };
  return cb;
}
// Двойник помощника clip-conceal.ps1 (путь секретов на Windows, W2-5): кладёт текст в тот же двойник буфера, мимо writeText.
// Подставляется всегда — иначе на win32 (CI) тест запускает настоящий PowerShell и пишет секрет в настоящий буфер.
const concealedInto = (cb) => async (secret) => { cb.text = Buffer.from(secret.bytes).toString("utf8"); cb.concealed++; return true; };
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
    clipboard: cb, writeConcealed: concealedInto(cb), copyText: (t) => { copied.push(t); return true; }, ...extra });
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
  assert.deepEqual(v.counts, { all: 5, anyDesk: 1, teamViewer: 1, other: 3 });
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

test("подробности: запись по ключу; «Показать» — «Доступ» из файла с пустыми строками, пароли под маской; копия паролей и «Доступа» — в буфер на 30 с; в журнале — только код поля", async () => {
  const a = await app();
  const details = await a.call("rc:details", a.key("Вінницька · Філія 2"));
  assert.equal(details.name, "Вінницька · Філія 2");
  noSecrets(details, "details");
  assert.deepEqual(await a.call("rc:revealAccess", a.key("Вінницька · Філія 2")), { ok: true, text: ACCESS.replace("пароль: Demo-77-выдумка", "пароль: ••••••") });
  assert.deepEqual(await a.call("rc:revealAccess", a.key("Озерна")), { ok: false });
  assert.deepEqual(await a.call("rc:copySecret", { key: a.key("Вінницька · Філія 2"), field: "accountPassword" }), { ok: true });
  assert.equal(a.cb.text, "Win-pass-2");
  assert.deepEqual([a.cb.concealed, a.cb.writes], [1, 0], "секрет — через помощник мимо журнала буфера, не writeText");
  assert.match(a.huds.at(-1).title, /Пароль учётки скопирован/);
  assert.match(a.huds.at(-1).detail, /30 с/);
  assert.deepEqual(await a.call("rc:copySecret", { key: a.key("Лісова"), field: "access" }), { ok: true });
  assert.equal(a.cb.text, "Профиль: лес");
  // Пароль подключения (карточка v2: ⧉ рядом с ID) — тем же путём; другие поля — нет.
  assert.deepEqual(await a.call("rc:copySecret", { key: a.key("Північна лабораторія"), field: "password", quiet: true }), { ok: true });
  assert.equal(a.cb.text, "AD-pass-1");
  assert.match(a.huds.at(-1).title, /«Доступ» скопирован/, "quiet — без тоста: подпись показывает карточка");
  assert.deepEqual(await a.call("rc:copySecret", { key: a.key("Північна лабораторія"), field: "contacts" }), { ok: false, error: "field" });
  assert.deepEqual(await a.call("rc:revealSecret", { key: a.key("Північна лабораторія"), field: "password" }), { ok: true, value: "AD-pass-1" });
  assert.deepEqual(await a.call("rc:revealSecret", { key: a.key("Північна лабораторія"), field: "accountPassword" }), { ok: false }, "👁 — только поля карточки");
  // Нет пароля учётки — честно «не удалось прочитать».
  assert.deepEqual(await a.call("rc:copySecret", { key: a.key("Озерна"), field: "accountPassword" }), { ok: false, error: "unavailable" });
  assert.deepEqual(a.log, ["copy ok field=accountPassword", "copy ok field=access", "copy ok field=password", "copy fail field=accountPassword"]);
  a.log.length = 0;
  noSecrets([a.huds, a.log], "тосты и журнал");
  // Адрес RDP — обычной копией (не секрет).
  assert.deepEqual(await a.call("rc:copyAddress", { key: a.key("Вінницька · Філія 2") }), { ok: true });
  assert.deepEqual(a.copied, ["10.20.0.15"]);
  // Выход из приложения: секрет не остаётся в буфере.
  await a.call("rc:copySecret", { key: a.key("Лісова"), field: "access" });
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
  assert.deepEqual([a.cb.concealed, a.cb.writes], [1, 0], "пункт меню — тем же путём мимо журнала буфера");
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

test("окно: метки и «Доступ» только через textContent; пароли — «••••••••», 👁 на 10 с, сами скрываются; при уходе с подробностей всё убирается", () => {
  const ui = path.join(__dirname, "..", "..", "remote", "ui");
  const js = fs.readFileSync(path.join(ui, "remote.js"), "utf8"), preload = fs.readFileSync(path.join(ui, "preload.js"), "utf8");
  assert.equal((js.match(/innerHTML/g) || []).length, 1);
  assert.ok(!/rc:revealAccount|revealPassword/.test(js + preload));
  assert.match(js, /const REVEAL_MS = 10_000, COPIED_MS = 30_000;/);
  assert.match(js, /if \(until && now >= until\) row\.hide\(\);/, "через 10 с значение скрывается само");
  assert.match(js, /if \(until\) \{ row\.hide\(\); row\.tick\(Date\.now\(\)\); return; \}/, "повторное 👁 — скрыть сразу");
  assert.match(js, /Показан · скроется через \$\{Math\.max\(1, Math\.ceil\(\(until - now\) \/ 1000\)\)\} с/);
  assert.match(js, /Скопирован · буфер очистится через 30 с/);
  assert.match(js, /function closeDetails\(\) \{\s*forgetSecrets\(\);[\s\S]{0,200}detailsBox"\)\?\.remove\(\)/, "при уходе с подробностей их узел (и показанное) удаляется");
  assert.match(js, /visibilitychange/, "окно скрыто — карточка перерисовывается без показанного");
  assert.match(js, /"без ID"/);
  assert.match(js, /пароли скрыты/);
});

// ---------- последние правки: «Как подключиться», «Контакты», палитра; секреты — мимо журнала буфера (W2-5) ----------
const access = require("../../remote/access");
const DEMO_KEY = "QUJDREVGR0g=";
const DEMO_ACCESS = `VPN WireGuard — сервер: vpn.demo.invalid:51820 · логин: demo-user · ключ: ${DEMO_KEY}\nRDP — IP: 192.0.2.10 · порт: 3390 · Login: demo-admin`;
const DEMO_CONTACTS = "Ольга (бухгалтерия) +38 (044) 000-00-00\nДежурный: 067 000 11 22, каб. 12";
const DEMO_FILE = xml([...ROWS,
  `<connection><name>Демо-лаборатория</name><id>111222333</id><tags>Рег, VPN</tags><access>${esc(DEMO_ACCESS)}</access><contacts>${esc(DEMO_CONTACTS)}</contacts><app>AnyDesk</app></connection>`]);
const DEMO_SECRETS = [DEMO_KEY, "Ольга", "000-00-00", "067 000", "Дежурный"];

test("телефоны в «Контактах»: цифры с + ( ) - и пробелами, не меньше 7 цифр; перенос строки телефон не продолжает", () => {
  assert.deepEqual(access.findPhones(DEMO_CONTACTS), ["+38 (044) 000-00-00", "067 000 11 22"]);
  assert.deepEqual(access.findPhones("Иван, 050 000 00 00"), ["050 000 00 00"]);
  assert.deepEqual(access.findPhones("каб. 12, тел. 12-34, 23.10.2026"), [], "короткие номера и даты — не телефоны");
  assert.deepEqual(access.findPhones("123\n4567"), []);
  for (const ok of ["+38 (044) 000-00-00", "0670001122"]) assert.ok(access.isPhone(ok), ok);
  for (const bad of ["12-34", "067 000 11 22; calc", "+38 (044) <b>", "1".repeat(25)]) assert.ok(!access.isPhone(bad), bad);
});

// Карточка v2 (task-rc-card-v2): шаги из блоков «Доступа», учётные записи — формы строк как в .audit/rc-access-shapes.txt, данные
// выдуманные. 1:1 с Mac (`ConnectionCardTests.swift`).
const rec = (o = {}) => ({ method: null, id: "123456789", tags: [], account: "", ...o });
const pairsOf = (card) => card.accounts.map((a) => `${a.kind}:${a.login ?? "—"}/${a.password ?? "—"}`);

test("карточка v2: L2TP с IP1/IP2/L2tpPsk, затем блоки RDP и Router; пары из шагов не повторяются; у роутера логин не указан", () => {
  const card = access.buildCard(rec({ method: "rdp", id: "", tags: ["Рег", "VPN", "RDP"], account: "Администратор" }), [
    "VPN — подключение средствами Windows, тип L2TP с общим ключом. Если первый сервер не отвечает — второй",
    "IP1: 203.0.113.10 · основной адрес для подключения через L2tp туннель",
    "IP2: 203.0.113.11 · запасной адрес для подключения через L2tp туннель",
    "L2tpPsk: Demo-Psk-10", "login: lims", "pass: demo-Vpn-7731", "",
    "RDP", "IP: 10.20.0.15", "login: lims", "pass: Demo-Rdp-13", "",
    "Router", "pass: Demo-Rtr-8"].join("\r\n"), "Demo-Win-1");
  assert.deepEqual(card.vpn, { kind: "L2TP/IPsec", server: "203.0.113.10", backupServer: "203.0.113.11", key: "Demo-Psk-10", login: "lims",
    password: "demo-Vpn-7731", note: "подключение средствами Windows, тип L2TP с общим ключом. Если первый сервер не отвечает — второй" });
  assert.deepEqual(card.rdp, { address: "10.20.0.15", login: "lims", password: "Demo-Rdp-13", useAccountsBelow: false });
  assert.deepEqual(pairsOf(card), ["windows:Администратор/Demo-Win-1", "router:—/Demo-Rtr-8"]);
  assert.deepEqual(card.accounts.map((a) => a.source), ["columns", "access"]);
});

test("карточка v2: RDP с несколькими «Логин · Пароль» — все в учётках, шаг только с адресом; RDP-блок с User/Password", () => {
  const many = access.buildCard(rec({ method: "rdp", id: "demo-lab.example.net", tags: ["RDP"] }), [
    "Філія · Адрес основний / резервний сервер 192.0.2.40 через шлюз · Логин: operator · Пароль: Demo-Op1-11",
    "Логин: operator2 · Пароль: demo-Op2-58", "Логин: lab.manager · Пароль: Demo-Mgr-33"].join("\n"), null);
  assert.equal(many.vpn, null);
  assert.deepEqual(many.rdp, { address: "demo-lab.example.net", login: null, password: null, useAccountsBelow: true });
  assert.deepEqual(pairsOf(many), ["windows:operator/Demo-Op1-11", "windows:operator2/demo-Op2-58", "windows:lab.manager/Demo-Mgr-33"]);
  const block = access.buildCard(rec({ tags: ["RDP"] }), [
    "RDP до сервера через основной канал — адрес 10.0.36.1", "Запасной канал RDP через другой порт IP:", "10.0.36.2",
    "User: Admin", "Password: Demo-Pw-36 · после · смены", "", "Бухгалтерия-2", "Окно-обслуживания"].join("\n"), null);
  assert.deepEqual(block.rdp, { address: "10.0.36.1", login: "Admin", password: "Demo-Pw-36", useAccountsBelow: false });
  assert.deepEqual(block.accounts, [], "одиночные слова без меток — не учётки");
});

test("карточка v2: FortiClient и PPTP («логин — пароль», «Роутер — VPN PPTP · IP:»), VPN с пояснением, многострочное пояснение", () => {
  const forti = access.buildCard(rec({ method: "rdp", id: "", tags: ["VPN", "RDP"] }), "FortiClient — шлюз · demo-gw\nvpnuser — Demo-Fc-12\nRDP — IP: 10.0.2.5", null);
  assert.deepEqual([forti.vpn.kind, forti.vpn.login, forti.vpn.password, forti.vpn.server, forti.rdp.address], ["FortiClient", "vpnuser", "Demo-Fc-12", null, "10.0.2.5"]);
  for (const first of ["Шлюз-1", "Роутер"]) {
    const pptp = access.buildCard(rec({ method: "vpn", id: "", tags: ["VPN"] }), `${first} — VPN PPTP · IP: 198.51.100.9\nLogin: admin\nPassword: Demo-Pptp-10\nКомпьютер — IP: 10.0.0.9`, null);
    assert.deepEqual([pptp.vpn.kind, pptp.vpn.server, pptp.vpn.login, pptp.vpn.password, pptp.rdp, pptp.accounts], ["PPTP", "198.51.100.9", "admin", "Demo-Pptp-10", null, []], first);
  }
  const note = access.buildCard(rec({ program: "anyDesk", tags: ["VPN", "RDP"] }),
    "VPN — 203.0.113.34 · подключение средствами Windows через встроенный клиент\nvpn34 — Demo-V34 · PPTP · шифрование обязательно для этого подключения\nRDP — 10.0.34.2", null);
  assert.deepEqual([note.vpn.server, note.vpn.kind, note.vpn.login, note.vpn.password, note.vpn.note, note.rdp.address],
    ["203.0.113.34", "PPTP", "vpn34", "Demo-V34", "подключение средствами Windows через встроенный клиент", "10.0.34.2"]);
  const multi = access.buildCard(rec({ tags: ["VPN"] }), [
    "AnyDesk: 123 456 789 пароль у заведующего", "",
    "Для входа в VPN использовать встроенный клиент Windows с типом подключения", "протокол туннеля выбирается автоматически при первом входе",
    "Login: lab25", "Password: Demo-V25", "IP: IP: 198.51.100.25", "логін і пароль такі ж як на сервер", "", "Администратор", "Demo-Adm-8"].join("\n"), null);
  assert.deepEqual([multi.vpn.server, multi.vpn.login, multi.vpn.password, multi.vpn.kind, multi.rdp, multi.accounts], ["198.51.100.25", "lab25", "Demo-V25", null, null, []]);
  assert.equal(multi.vpn.note, "Для входа в VPN использовать встроенный клиент Windows с типом подключения протокол туннеля выбирается автоматически при первом входе логін і пароль ••••••");
});

test("карточка v2: «Учётка Server», Router одной строкой, «логин — пароль» и пароль отдельным блоком; ничего не выдумывается", () => {
  const server = access.buildCard(rec({ program: "teamViewer", tags: ["RDP"], account: "Администратор" }),
    "Учётка Server — логин и пароль в колонках «Учётная запись» и «Пароль учётной записи»\nServer — логин: Администратор · пароль: Demo-Srv-8\n\nRDP — IP: 10.0.22.1", "Demo-Srv-8");
  assert.deepEqual(pairsOf(server), ["server:Администратор/Demo-Srv-8"]);
  assert.deepEqual(server.rdp, { address: "10.0.22.1", login: null, password: null, useAccountsBelow: false });
  assert.deepEqual(pairsOf(access.buildCard(rec({ account: "Администратор" }), "Server — логин: Администратор · пароль: Demo-Other-1", "Demo-Win-2")),
    ["windows:Администратор/Demo-Win-2", "server:Администратор/Demo-Other-1"]);
  const generic = access.buildCard(rec({ tags: ["RDP"] }), "Router / pass: Demo-R1\n\nАдминистратор — Demo-Adm-15\n\nrdp — 10.0.31.1\n\nLims\n\nпароль: Demo-P31", null);
  assert.deepEqual(pairsOf(generic), ["router:—/Demo-R1", "windows:Администратор/Demo-Adm-15", "windows:—/Demo-P31"]);
  assert.equal(generic.rdp.useAccountsBelow, true);
  assert.deepEqual(access.buildCard(rec(), "AnyDesk: 123 456 789\nLOCAL IP: 10.1.1.1\nIP: 10.1.1.2 · касса на втором этаже", null), { vpn: null, rdp: null, accounts: [] });
  const bare = access.buildCard(rec({ tags: ["VPN", "RDP"] }), "VPN включено\nRDP\nServer", null);
  assert.deepEqual([bare.vpn, bare.rdp.address, bare.accounts], [{ kind: null, server: null, backupServer: null, key: null, login: null, password: null, note: null }, null, []]);
  assert.deepEqual(pairsOf(access.buildCard(rec({ account: "kassa" }), null, null)), ["windows:kassa/—"]);
  assert.equal(access.buildCard(rec({ tags: ["RDP"] }), "RDP — IP: 10.20.0.15 · порт 3390", null).rdp.address, "10.20.0.15:3390");
});

test("карточка v2 для окна: без паролей и ключей — признаки и id для 👁/⧉; значение — cardSecret по id", () => {
  const record = rec({ id: "111222333", tags: ["Рег", "VPN"] });
  const full = access.buildCard(record, DEMO_ACCESS, null);
  const pub = access.publicCard(record, full);
  assert.deepEqual(pub.vpn, { kind: "WireGuard", server: "vpn.demo.invalid:51820", backupServer: null, login: "demo-user", note: null, hasKey: true, hasPassword: false });
  assert.deepEqual(pub.rdp, { address: "192.0.2.10:3390", login: "demo-admin", useAccountsBelow: false, hasPassword: false, canOpen: true, fromAccess: true });
  assert.ok(!JSON.stringify(pub).includes(DEMO_KEY));
  assert.equal(access.cardSecret(full, "vpn.key"), DEMO_KEY, "ключ целиком, с «=» в конце");
  assert.equal(access.cardSecret(full, "vpn.password"), null);
  assert.equal(access.cardSecret(full, "account.0123456789ab.0"), null);
  for (const id of ["vpn.key", "vpn.password", "rdp.password", "account.0123456789ab.0", "account.0123456789ab.12"]) assert.ok(access.CARD_SECRETS.test(id), id);
  for (const id of ["password", "access", "account.", "account.x", "account.0", "vpn.key2"]) assert.ok(!access.CARD_SECRETS.test(id), id);
});

test("контакты v2: многострочная должность — одна строка; телефон — кнопка; нет телефона — «Телефона в файле нет»; номер — +380…", () => {
  assert.deepEqual(access.parseContacts("Іваненко Олена\nЗаступник директора\nвірусологічного відділу\n050 000 00 01\n\nАдміністратор мережі\n\n"
    + "Ольга (бухгалтерия) +38 (044) 000-00-00\nДежурный: 067 000 11 22, каб. 12\nСклад 050 000 00 02, 050 000 00 03"), [
    { title: "Іваненко Олена", detail: "Заступник директора вірусологічного відділу", phones: ["050 000 00 01"] },
    { title: "Адміністратор мережі", detail: null, phones: [] },
    { title: "Ольга (бухгалтерия)", detail: null, phones: ["+38 (044) 000-00-00"] },
    { title: "Дежурный", detail: "каб. 12", phones: ["067 000 11 22"] },
    { title: "Склад", detail: null, phones: ["050 000 00 02", "050 000 00 03"] },
  ]);
  assert.deepEqual(access.parseContacts("Заступник директора\r\nвірусологічного відділу"), [{ title: "Заступник директора вірусологічного відділу", detail: null, phones: [] }]);
  const cases = [["050 000 00 01", "+380500000001"], ["+38 (044) 000-00-00", "+380440000000"], ["380670001122", "+380670001122"], ["8 050 000 00 01", "+380500000001"],
    ["500000001", "+380500000001"], ["+48 600 000 000", "+48600000000"], ["12-34", null], ["0500000", null], ["050 000 00 0123", null]];
  for (const [raw, want] of cases) assert.equal(access.dialable(raw), want, raw);
  assert.equal(access.telURL("050 000 00 01"), "tel:+380500000001");
});

test("звонок: обработчик tel:/callto: — по реестру, только чтение (reg query); UniTalk → tel:+380…, иначе номер копируется", async () => {
  const dialer = require("../../remote/dialer");
  assert.deepEqual(dialer.callPlan("050 000 00 01", true), { call: "tel:+380500000001" });
  assert.deepEqual(dialer.callPlan(" 050 000 00 01 ", false), { copy: "050 000 00 01", reason: "noUniTalk" });
  assert.deepEqual(dialer.callPlan("каб. 12-34", true), { copy: "каб. 12-34", reason: "notANumber" });
  assert.equal(dialer.regValue("\r\nHKEY_CURRENT_USER\\...\\UserChoice\r\n    ProgId    REG_SZ    UniTalk.tel\r\n"), "UniTalk.tel");
  assert.equal(dialer.regValue("    (Default)    REG_EXPAND_SZ    \"C:\\Program Files\\UniTalk\\UniTalk.exe\" \"%1\"\r\n"), "\"C:\\Program Files\\UniTalk\\UniTalk.exe\" \"%1\"");
  // Двойник execFile: реестр — словарь; запись в реестр невозможна (только query).
  const run = (reg) => {
    const calls = [];
    const execFile = (file, args, opts, cb) => {
      calls.push([path.win32.basename(file), ...args]);
      assert.equal(args[0], "query", "только чтение");
      assert.equal(opts.windowsHide, true);
      const v = reg[args[1]];
      setImmediate(() => (v == null ? cb(new Error("not found"), "") : cb(null, `\r\n${args[1]}\r\n    x    REG_SZ    ${v}\r\n`)));
    };
    return { calls, lookup: dialer.createHandlerLookup(execFile) };
  };
  const UC = (s) => `HKCU\\Software\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\${s}\\UserChoice`;
  const chosen = run({ [UC("tel")]: "UniTalk.tel", "HKCR\\UniTalk.tel\\shell\\open\\command": "\"C:\\UniTalk\\UniTalk.exe\" \"%1\"" });
  assert.equal(await chosen.lookup.isUniTalk(), true);
  assert.deepEqual(chosen.calls, [["reg.exe", "query", UC("tel"), "/v", "ProgId"], ["reg.exe", "query", "HKCR\\UniTalk.tel\\shell\\open\\command", "/ve"]]);
  assert.equal(await run({ "HKCR\\callto\\shell\\open\\command": "\"C:\\Program Files\\UniTalk\\UniTalk.exe\" %1" }).lookup.isUniTalk(), true, "без выбора пользователя — HKCR, и callto: тоже");
  assert.equal(await run({ [UC("tel")]: "ChromeHTML", "HKCR\\ChromeHTML\\shell\\open\\command": "chrome.exe %1" }).lookup.isUniTalk(), false);
  assert.equal(await run({ [UC("tel")]: "bad\\..\\key" }).lookup.isUniTalk(), false, "странный ProgId в путь реестра не подставляется");
  assert.equal(await dialer.createHandlerLookup(null).isUniTalk(), false, "не Windows — реестра нет");

  // Через IPC: двойник звонилки — UniTalk не запускается; без UniTalk — номер в буфер и «UniTalk не найден — номер скопирован».
  const opened = [];
  let uniTalk = true;
  const a = await app({ file: DEMO_FILE, extra: { dialer: { isUniTalk: async () => uniTalk, open: async (url) => { opened.push(url); } } } });
  assert.deepEqual(await a.call("rc:call", "067 000 11 22"), { ok: true, call: true });
  assert.deepEqual(opened, ["tel:+380670001122"]);
  assert.deepEqual(a.copied, []);
  uniTalk = false;
  assert.deepEqual(await a.call("rc:call", "067 000 11 22"), { ok: true, call: false, reason: "noUniTalk" });
  assert.deepEqual(a.copied, ["067 000 11 22"]);
  assert.equal(a.huds.at(-1).title, "UniTalk не найден — номер скопирован");
  assert.deepEqual(await a.call("rc:call", "calc.exe & 0670001122"), { ok: false, error: "phone" });
  assert.equal(opened.length, 1);
  assert.deepEqual(a.log, ["call ok", "call copy reason=noUniTalk"], "номер в журнал не пишется");
  a.rc.dispose();
});

test("карточка через IPC: шаги, учётки и контакты — из файла по запросу; паролей и ключей в ответе нет; 👁 и ⧉ — по id, файл читается заново", async () => {
  const a = await app({ file: DEMO_FILE });
  const key = a.key("Демо-лаборатория");
  const info = await a.call("rc:cardInfo", key);
  assert.equal(info.ok, true);
  assert.deepEqual(info.card.vpn, { kind: "WireGuard", server: "vpn.demo.invalid:51820", backupServer: null, login: "demo-user", note: null, hasKey: true, hasPassword: false });
  assert.deepEqual(info.card.rdp, { address: "192.0.2.10:3390", login: "demo-admin", useAccountsBelow: false, hasPassword: false, canOpen: true, fromAccess: true });
  assert.deepEqual(info.contacts, [{ title: "Ольга (бухгалтерия)", detail: null, phones: ["+38 (044) 000-00-00"] }, { title: "Дежурный", detail: "каб. 12", phones: ["067 000 11 22"] }]);
  assert.ok(!JSON.stringify(info).includes(DEMO_KEY), "ключ VPN окну не уходит");
  assert.deepEqual(await a.call("rc:revealSecret", { key, field: "vpn.key" }), { ok: true, value: DEMO_KEY });
  assert.deepEqual(await a.call("rc:revealSecret", { key, field: "vpn.password" }), { ok: false });
  assert.deepEqual(await a.call("rc:revealSecret", { key, field: "../access" }), { ok: false });
  // Запись RDP: адрес — её ID; учётки — колонки, Server и «Login: operator».
  const branch = await a.call("rc:cardInfo", a.key("Вінницька · Філія 2"));
  assert.equal(branch.card.rdp.address, "10.20.0.15");
  assert.equal(branch.card.rdp.useAccountsBelow, true);
  const ids = branch.card.accounts.map((x) => x.id);
  assert.deepEqual(branch.card.accounts.map(({ id, ...rest }) => rest), [
    { kind: "windows", source: "columns", login: "lims.admin", hasPassword: true },
    { kind: "server", source: "access", login: "lims.admin", hasPassword: true },
    { kind: "windows", source: "access", login: "operator", hasPassword: false }]);
  assert.deepEqual(ids, access.accountIds(access.buildCard({ account: "lims.admin", tags: [] }, null, null).accounts.concat(
    [{ kind: "server", login: "lims.admin" }, { kind: "windows", login: "operator" }])), "id — от подписи и логина, не от места в списке");
  assert.ok(!JSON.stringify(branch).includes("Win-pass-2") && !JSON.stringify(branch).includes("Demo-77"));
  assert.deepEqual(await a.call("rc:revealSecret", { key: a.key("Вінницька · Філія 2"), field: ids[1] }), { ok: true, value: "Demo-77-выдумка" });
  assert.deepEqual(await a.call("rc:copySecret", { key: a.key("Вінницька · Філія 2"), field: ids[0], quiet: true }), { ok: true });
  assert.equal(a.cb.text, "Win-pass-2");
  // Без «Доступа» и «Контактов» — пусто; метка VPN без строк — пустой шаг VPN.
  const plain = await a.call("rc:cardInfo", a.key("Східна"));
  assert.deepEqual([plain.contacts, plain.card.rdp, plain.card.accounts], [[], null, []]);
  assert.deepEqual(plain.card.vpn, { kind: null, server: null, backupServer: null, login: null, note: null, hasKey: false, hasPassword: false });
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
  assert.deepEqual(a.log, ["copy ok field=account"], "чтение карточки и 👁 в журнал не пишутся; копия — только код поля");
  a.rc.dispose();
});

test("RW-1 / v2: «Доступ · как в файле» — после метки пароля маска до конца строки, ещё в основном процессе; пояснение «Из файла» — тоже", async () => {
  const RAW_ACCESS = "RDP — сервер srv01 · логин: admin · пароль: Qw3rty-выдумка\nL2TP VPN · L2tpPsk=Demo-Psk-1 · Password: Demo Pass 2 | профиль у админа";
  const cases = {
    "VPN pass Demo-3": "VPN pass ••••••", "VPN, пароля: Demo-4": "VPN, пароля: ••••••", "VPN WireGuard key = QUJD=": "VPN WireGuard key = ••••••",
    "VPN PSK: Demo-5; сервер vpn.demo.invalid": "VPN PSK: ••••••", "VPN pre-shared key — Demo-6": "VPN pre-shared key — ••••••",
    "RDP pwd:Demo-7": "RDP pwd:••••••", "RDP secret Demo-8 · порт 3389": "RDP secret ••••••", "RDP — пароль:": "RDP — пароль:",
    "VPN Passport office · keyboard US": "VPN Passport office · keyboard US", "тип L2TP с общим ключом. Если": "тип L2TP с общим ключом. Если",
  };
  for (const [line, want] of Object.entries(cases)) assert.equal(access.maskSecrets(line), want, line);
  const a = await app({ file: xml([...ROWS, `<connection><name>Без адреса</name><id>111222334</id><tags>VPN, RDP</tags><access>${esc(RAW_ACCESS)}</access><app>AnyDesk</app></connection>`]) });
  const key = a.key("Без адреса");
  const info = await a.call("rc:cardInfo", key);
  assert.equal(info.card.rdp.address, null, "имя без точки — не адрес");
  assert.equal(info.card.vpn.hasKey, true);
  assert.deepEqual((await a.call("rc:revealAccess", key)).text.split("\n"),
    ["RDP — сервер srv01 · логин: admin · пароль: ••••••", "L2TP VPN · L2tpPsk=••••••"]);
  for (const x of ["Qw3rty", "Demo-Psk-1", "Demo Pass 2"]) assert.ok(!JSON.stringify([info, await a.call("rc:revealAccess", key)]).includes(x), x);
  a.rc.dispose();
});

test("W2-5: ключ VPN, пароль учётки и «Доступ» — в буфер через помощник мимо журнала Win+V и облака; не вышло — ничего не скопировано", async () => {
  const concealed = [];
  let works = true;
  const writeConcealed = async (secret) => { concealed.push(Buffer.from(secret.bytes).toString("utf8")); return works; };
  const a = await app({ file: DEMO_FILE, extra: { writeConcealed } });
  const key = a.key("Демо-лаборатория");
  assert.deepEqual(await a.call("rc:copySecret", { key, field: "vpn.key" }), { ok: true });
  assert.deepEqual(concealed, [DEMO_KEY], "ключ целиком, с «=» в конце");
  assert.equal(a.cb.writes, 0, "обычным writeText секрет не пишется");
  assert.equal(a.huds.at(-1).title, "Пароль скопирован");
  assert.match(a.huds.at(-1).detail, /30 с/);
  assert.deepEqual(await a.call("rc:copySecret", { key: a.key("Вінницька · Філія 2"), field: "accountPassword" }), { ok: true });
  assert.equal(concealed.at(-1), "Win-pass-2");
  // У записи без ключа VPN — честно «не удалось».
  assert.deepEqual(await a.call("rc:copySecret", { key: a.key("Вінницька · Філія 2"), field: "vpn.key" }), { ok: false, error: "unavailable" });
  works = false;
  assert.deepEqual(await a.call("rc:copySecret", { key, field: "access" }), { ok: false });
  assert.equal(a.cb.writes, 0, "помощник не справился — секрет не уходит в буфер обычным текстом");
  assert.equal(a.huds.at(-1).kind, "warning");
  assert.deepEqual(a.log, ["copy ok field=vpn.key", "copy ok field=accountPassword", "copy fail field=vpn.key", "copy fail field=access"]);
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

test("палитра: «Обновить» (↻) — справа в строке подсказок; Excel, папка, «Добавить», настройки и «Загружено N · …» — в окне списка; контакты — только в карточке", () => {
  const ui = path.join(__dirname, "..", "..", "remote", "ui");
  // CRLF при выгрузке на Windows (autocrlf) — сравниваем с LF.
  const js = fs.readFileSync(path.join(ui, "remote.js"), "utf8").replace(/\r\n/g, "\n"), html = fs.readFileSync(path.join(ui, "remote.html"), "utf8");
  for (const id of ["openFile", "folderBtn", "reload", "addBtn", "settingsBtn", "summary"]) assert.match(html, new RegExp(`id="${id}"`), id);
  assert.match(html, /id="reload"[^>]*aria-label="Обновить">↻</);
  // rc-win-entry A: панель палитры не висит отдельной строкой — «Обновить» в строке подсказок справа.
  const pal = js.slice(js.indexOf("if (palette) {\n  $(\"hints\").hidden = false;"));
  assert.match(pal, /\$\("bar"\)\.hidden = true;/);
  assert.match(pal, /el\("button", "btn c ic", "↻"\)[\s\S]{0,200}window\.rc\.reload\(\)[\s\S]{0,40}\$\("hints"\)\.append\(again\)/);
  assert.match(js, /function renderSummary\(\) \{[^}]*if \(palette\) \{ s\.textContent = ""; return; \}/);
  assert.match(js, /\$\("addBtn"\)\.hidden = palette \|\|/);
  assert.match(js, /\$\("folderBtn"\)\.onclick = \(\) => window\.rc\.showFolder\(\)/);
  const row = js.slice(js.indexOf("function rowElement"), js.indexOf("function fitAllLabels"));
  assert.ok(!/contacts|phone/i.test(row), "в строке списка контактов нет");
  assert.ok(js.indexOf("contactsCard(contacts)") > js.indexOf("async function renderDetails"));
  assert.ok(js.indexOf("contactsCard(contacts)") > js.indexOf("accessCard(r)"), "контакты — в самом низу карточки");
  // Пароли и ключи — только точки, 👁 и ⧉ по id (значение даёт и копирует основной процесс).
  assert.match(js, /window\.rc\.revealSecret\(r\.key, id\)/);
  assert.match(js, /window\.rc\.copySecret\(r\.key, id, true\)/);
  const cardJs = js.slice(js.indexOf("function stepsCard"), js.indexOf("function accessCard"));
  assert.ok(!/(?<!")\b(?:v|d|a|vpn|rdp)\.(?:key|password|secret)\b/.test(cardJs), "в карточку значения не приходят — только hasKey/hasPassword");
  assert.match(cardJs, /v\.hasKey/);
});

// ---------- ревью карточки v2 (.audit/review-rc-card-v2.md): 1:1 с Mac (`ConnectionCardTests`) ----------

test("ревью v2, FIX 1: «Доступ · как в файле» — ни одного пароля открыто (формы row 2, 3, 10, 11/17, 12/27, 21, 25/35, 34, 36–38)", async () => {
  const text = [
    "Учётка Server — логин и пароль в колонках", "FortiClient — шлюз · demo-gw", "vpnuser — Demo-Fc-12", "lims — Demo-Lims-12",
    "Перевірка доступу на сервері — Администратор · Demo-Tail-11", "RDP — 10.0.11.1 · LIMS · Demo-Rdp-17", "Администратор — Demo-Adm-15",
    "vpn34 — Demo-V34 · PPTP · шифрование обязательно для этого подключения", "User: Admin", "Password: Demo-Pw-36 · Demo-Pw2-8 · Demo-Pw3-10",
    "pass: ab;cd-Demo", "Пароль: Demo, with comma", "", "Администратор", "Demo-Col-8", "IP: 10.0.0.9 · кабинет 12"].join("\n");
  const record = { method: null, id: "123456789", tags: ["VPN", "RDP"], account: "Администратор" };
  const card = access.buildCard(record, text, "Demo-Win-1");
  const shown = access.maskedAccess(`${text}\nAnyDesk пароль подключения как в колонке: Demo-ID-9 \nкопия Demo-Win-1`, [...access.cardSecrets(card), "Demo-ID-9"]);
  for (const secret of ["Demo-Fc-12", "Demo-Lims-12", "Demo-Tail-11", "Demo-Rdp-17", "Demo-Adm-15", "Demo-V34", "Demo-Pw-36", "Demo-Pw2-8", "Demo-Pw3-10",
    "ab;cd", "cd-Demo", "with comma", "Demo-Col-8", "Demo-ID-9", "Demo-Win-1"]) assert.ok(!shown.includes(secret), `открыто: ${secret}`);
  for (const kept of ["Учётка Server", "FortiClient", "RDP — 10.0.11.1", "User: Admin", "IP: 10.0.0.9 · кабинет 12", "PPTP", "vpnuser — ••••••"]) {
    assert.ok(shown.includes(kept), `должно остаться: ${kept}`);
  }
  assert.equal(access.maskedAccess("a\r\nb c\r\n", []), "••••••\r\nb c\r\n");
  assert.equal(access.maskedAccess("Demo-X1x · Demo-X1xx", ["Demo-X1x"]), "•••••• · ••••••");

  // Через IPC: пароль ID и пароль учётки из колонки — по значению; окно скрывает показанное через 10 с.
  const file = xml([`<connection><name>Демо-доступ</name><id>222333444</id><password>Demo-ID-77</password><tags>RDP</tags><account>Администратор</account><accountPassword>Demo-Win-77</accountPassword><access>${esc("копия пароля ID: см. AnyDesk\nRDP — 10.0.11.1 · LIMS · Demo-ID-77\nстарый Demo-Win-77 рабочий")}</access><app>AnyDesk</app></connection>`]);
  const a = await app({ file });
  const res = await a.call("rc:revealAccess", a.key("Демо-доступ"));
  assert.equal(res.ok, true);
  for (const x of ["Demo-ID-77", "Demo-Win-77"]) assert.ok(!res.text.includes(x), x);
  assert.deepEqual(a.log, [], "показ «Доступа» в журнал не пишется");
  a.rc.dispose();
  const js = fs.readFileSync(path.join(__dirname, "..", "..", "remote", "ui", "remote.js"), "utf8");
  const card2 = js.slice(js.indexOf("function accessCard"), js.indexOf("function contactsCard"));
  assert.match(card2, /until = Date\.now\(\) \+ REVEAL_MS;/, "«Доступ» показывается 10 с");
  assert.match(card2, /if \(until && now >= until\) hide\(\);/, "и скрывается сам");
  assert.match(card2, /secretRows\.set\("access"/, "при уходе с подробностей забывается вместе с остальными");
});

test("ревью v2, FIX 2: «слово — слово» не придумывает учётку (row 39, модель, телефон, ID)", () => {
  const rec = { method: null, id: "123456789", tags: [], account: "" };
  for (const text of ["Справка — 0501234567 · ночь · 123456789", "Принтер — HP", "Телефон — 0501234567", "Склад — касса", "Каса — 1234567890"]) {
    assert.deepEqual(access.buildCard(rec, text, null).accounts, [], text);
  }
  assert.deepEqual(access.buildCard(rec, "delta — Demo-D-4", null).accounts.map((x) => [x.login, x.password]), [["delta", "Demo-D-4"]]);
  const vpn = access.buildCard({ ...rec, tags: ["VPN"] }, "VPN PPTP\nshort — Ab1\nТелефон — 050 123 45 67", null).vpn;
  assert.deepEqual([vpn.login, vpn.password], ["short", "Ab1"], "в блоке VPN пара без строгих условий, но номер — не пароль");
});

test("ревью v2, FIX 3 и п. 8 Тестера: пароль и ключ — целиком; сервер — только хост, явная метка сильнее прозы", () => {
  const rec = { method: null, id: "123456789", tags: [], account: "" };
  const cases = [["pass: ab;cd", "ab;cd"], ["Пароль: ab, cd", "ab, cd"], ["пароль: -Qw1", "-Qw1"], ["password = =Qw2=", "=Qw2="],
    ["Password: Demo-12 · после · смены", "Demo-12"], ["пароль — a / b", "a / b"], ["pass:Qw:3", "Qw:3"]];
  for (const [text, want] of cases) assert.equal(access.buildCard(rec, text, null).accounts[0]?.password, want, text);
  assert.equal(access.buildCard({ ...rec, tags: ["VPN"] }, "VPN L2TP\nL2tpPsk: k;e,y / 1", null).vpn.key, "k;e,y / 1");
  assert.deepEqual(access.buildCard(rec, "login: alpha / pass: Demo-A-1", null).accounts.map((x) => [x.login, x.password]), [["alpha", "Demo-A-1"]]);
  const vpnRec = { method: "vpn", id: "", tags: ["VPN"], account: "" };
  const prose = access.buildCard(vpnRec, "VPN — сервер: второй\nIP2: запасной", null).vpn;
  assert.deepEqual([prose.server, prose.backupServer], [null, null]);
  assert.equal(access.buildCard(vpnRec, "VPN — подключение средствами Windows, тип L2TP с общим ключом, при недоступности первого адреса второй\nIP1: 198.51.100.10", null).vpn.server, "198.51.100.10");
  assert.equal(access.buildCard(vpnRec, "VPN — 203.0.113.1 · подключение через встроенный клиент Windows\nСервер: 203.0.113.2", null).vpn.server, "203.0.113.2");
});

test("ревью v2, п. 5 и мелочи: «одной из учёток» — только Windows/Server; номер +380 — ровно 12 цифр, 00 — как +; UniTalk не открылся — номер скопирован", async () => {
  const one = access.buildCard({ method: null, id: "1", tags: ["RDP"], account: "Администратор" }, "RDP — 10.0.0.5\n\nRouter\npass: Demo-R-1", "Demo-W-1");
  assert.equal(one.accounts.length, 2);
  assert.equal(one.rdp.useAccountsBelow, false);
  assert.equal(access.dialable("+380 50 000 00 01 1"), null);
  assert.equal(access.dialable("3805000000011"), null);
  assert.equal(access.dialable("00380 50 000 00 01"), "+380500000001");
  assert.equal(access.dialable("0048 600 000 000"), "+48600000000");
  const a = await app({ file: DEMO_FILE, extra: { dialer: { isUniTalk: async () => true, open: async () => { throw new Error("no handler"); } } } });
  assert.deepEqual(await a.call("rc:call", "067 000 11 22"), { ok: true, call: false, reason: "openFailed" });
  assert.deepEqual(a.copied, ["067 000 11 22"]);
  assert.equal(a.huds.at(-1).title, "UniTalk не открылся — номер скопирован");
  a.rc.dispose();
});

test("fix2: id учётки стабилен при правке файла; учётки с таким id нет — «Файл изменился — откройте карточку заново», ничего не показано и не скопировано", async () => {
  // Одинаковые подпись и логин — номер среди одинаковых; другая учётка выше в списке id не сдвигает.
  const ids = access.accountIds([{ kind: "windows", login: "a" }, { kind: "router", login: null }, { kind: "windows", login: "a" }]);
  assert.equal(ids[0].replace(/\.\d+$/, ""), ids[2].replace(/\.\d+$/, ""));
  assert.deepEqual([ids[0].endsWith(".0"), ids[2].endsWith(".1")], [true, true]);
  assert.equal(access.accountIds([{ kind: "router", login: null }])[0], ids[1], "id роутера не зависит от того, что выше");
  assert.notEqual(access.accountIds([{ kind: "server", login: "a" }])[0].replace(/\.\d+$/, ""), ids[0].replace(/\.\d+$/, ""), "подпись входит в id");

  const row = (accessText) => xml([`<connection><name>Сервер</name><id>333444555</id><tags>RDP</tags><access>${esc(accessText)}</access><app>AnyDesk</app></connection>`]);
  const a = await app({ file: row("Router\npass: Demo-R-1\n\nadmin — Demo-Adm-1") });
  const key = a.key("Сервер");
  const before = (await a.call("rc:cardInfo", key)).card.accounts;
  assert.deepEqual(before.map((x) => [x.kind, x.login]), [["router", null], ["windows", "admin"]]);
  // В файл выше дописана ещё одна учётка: по индексу «account.1» открылась бы она; по стабильному id — та же «admin».
  fs.writeFileSync(a.list, row("oper — Demo-Op-9\n\nRouter\npass: Demo-R-1\n\nadmin — Demo-Adm-1"));
  await a.rc.store.reload?.();
  for (let i = 0; i < 100 && !(await a.call("rc:cardInfo", a.key("Сервер"))).card?.accounts.some((x) => x.login === "oper"); i++) await new Promise((r) => setTimeout(r, 10));
  const key2 = a.key("Сервер");
  assert.deepEqual(await a.call("rc:revealSecret", { key: key2, field: before[1].id }), { ok: true, value: "Demo-Adm-1" });
  // Учётку удалили из файла: тот же id — «Файл изменился», ни показа, ни копии.
  fs.writeFileSync(a.list, row("Router\npass: Demo-R-1"));
  await a.rc.store.reload?.();
  for (let i = 0; i < 100 && (await a.call("rc:cardInfo", a.key("Сервер"))).card?.accounts.length !== 1; i++) await new Promise((r) => setTimeout(r, 10));
  const key3 = a.key("Сервер");
  const writesBefore = a.cb.writes + a.cb.concealed;
  assert.deepEqual(await a.call("rc:revealSecret", { key: key3, field: before[1].id }), { ok: false, error: "changed" });
  assert.equal(a.huds.at(-1).title, "Файл изменился — откройте карточку заново");
  assert.deepEqual(await a.call("rc:copySecret", { key: key3, field: before[1].id, quiet: true }), { ok: false, error: "changed" });
  assert.equal(a.cb.writes + a.cb.concealed, writesBefore, "ничего не скопировано");
  assert.equal(a.huds.at(-1).title, "Файл изменился — откройте карточку заново");
  assert.deepEqual(await a.call("rc:revealSecret", { key: key3, field: before[0].id }), { ok: true, value: "Demo-R-1" }, "оставшаяся учётка — по своему id");
  assert.deepEqual(a.log, ["copy fail field=account changed"], "в журнале — код, без логина и хэша");
  a.rc.dispose();
});

test("ревью v2b: одно слово сразу после заголовка блока (row 13 «VPN …») и ведущий «-» пароля — под маской; строки AnyDesk не трогаются", () => {
  const lone = [["VPN Qw3rty-13", "VPN ••••••"], ["RDP Demo17", "RDP ••••••"], ["Router Demo-R", "Router ••••••"], ["Server Srv-1", "Server ••••••"],
    ["FortiClient fc-pass", "FortiClient ••••••"], ["L2TP l2", "L2TP ••••••"], ["PPTP pp9", "PPTP ••••••"], ["RDP — Demo-17", "RDP — ••••••"],
    ["VPN WireGuard", "VPN WireGuard"], ["RDP 10.0.13.1", "RDP 10.0.13.1"], ["VPN включено сегодня", "VPN включено сегодня"],
    ["AnyDesk: 123456789 demo-pc office", "AnyDesk: 123456789 demo-pc office"], ["AnyDesk demo-pc", "AnyDesk demo-pc"]];
  for (const [line, want] of lone) assert.equal(access.maskedAccess(line, []), want, line);
  const shown = access.maskedAccess("VPN Demo-Name-11\nRDP — 10.0.13.2", []);
  assert.ok(!shown.includes("Demo-Name-11"));
  assert.ok(shown.includes("RDP — 10.0.13.2"));
  const dash = [["пароль: -Qw1", "пароль: ••••••"], ["pass -Qw2", "pass ••••••"], ["password = -=Qw3", "password = ••••••"], ["L2tpPsk=-k1", "L2tpPsk=••••••"],
    ["пароль — -Qw4", "пароль — ••••••"], ["pwd:Demo-7", "pwd:••••••"], ["RDP — пароль:", "RDP — пароль:"], ["с общим ключом. Если", "с общим ключом. Если"]];
  for (const [line, want] of dash) {
    assert.equal(access.maskSecrets(line), want, line);
    assert.ok(!access.maskedAccess(line, []).includes("Qw"), line);
  }
});
