// Приёмка карточки подключения v2 (.audit/task-rc-card-v2.md), Windows: независимые проверки buildCard / publicCard / cardSecret,
// dialable / telURL / parseContacts, dialer (реестр — двойник execFile), фильтр «Другое». Данные выдуманные (IP из диапазонов
// документации); формы строк — по .audit/rc-access-shapes.txt. Ничего не запускается: ни PowerShell, ни reg.exe, ни UniTalk.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const access = require("../../remote/access");
const dialer = require("../../remote/dialer");
const lists = require("../../remote/lists");
const { ConnectionSearch } = require("../../remote/search");

const rec = (o = {}) => ({ sourceRow: 2, name: "Демо", id: "111222333", group: "", tags: [], note: "", method: null, program: null,
  account: "", hasAccountPassword: false, ...o });
const flat = (accounts) => accounts.map((a) => `${a.kind}|${a.login ?? "—"}|${a.password ?? "—"}`);

// ---------- 2. Шаги и учётки по формам «Доступа» ----------

test("форма row 24: L2TP с IP1/IP2/PSK, затем RDP с логином, затем Router без логина", () => {
  const text = [
    "VPN — подключение средствами Windows, тип L2TP с общим ключом",
    "IP1: 198.51.100.10 · основной адрес для туннеля L2tp",
    "IP2: 198.51.100.11 · запасной адрес для туннеля L2tp",
    "L2tpPsk: Demo-Psk-001",
    "login: demo.vpn",
    "pass: Demo-VpnPass-1",
    "",
    "RDP",
    "IP: 10.9.8.7",
    "login: demo.rdp",
    "pass: Demo-RdpPass-2",
    "",
    "Router",
    "pass: Demo-RouterPass-3",
  ].join("\n");
  const card = access.buildCard(rec({ method: "rdp", id: "", tags: ["Рег", "VPN", "RDP"] }), text, null);
  assert.equal(card.vpn.kind, "L2TP/IPsec");
  assert.equal(card.vpn.server, "198.51.100.10");
  assert.equal(card.vpn.backupServer, "198.51.100.11", "IP2 — запасной сервер");
  assert.equal(card.vpn.key, "Demo-Psk-001", "L2tpPsk — общий ключ");
  assert.equal(card.vpn.login, "demo.vpn");
  assert.equal(card.vpn.password, "Demo-VpnPass-1");
  assert.deepEqual({ address: card.rdp.address, login: card.rdp.login, password: card.rdp.password },
    { address: "10.9.8.7", login: "demo.rdp", password: "Demo-RdpPass-2" });
  assert.deepEqual(flat(card.accounts), ["router|—|Demo-RouterPass-3"], "пары из шагов повторно не выводятся; у Router логин не указан");
});

test("пояснение в строке VPN — проза: слова «адрес», «сервер», «логин и пароль» не дают сервер, логин или пароль", () => {
  const prose = [
    "VPN — подключение средствами Windows, тип L2TP с общим ключом, при недоступности первого адреса второй",
    "VPN — если сервер не отвечает, используйте запасной",
    "VPN — адрес сервера уточните у администратора",
    "VPN — логин и пароль как для почты",
  ];
  for (const line of prose) {
    const card = access.buildCard(rec({ method: "vpn", id: "", tags: ["VPN"] }), `${line}\nIP1: 198.51.100.10\nlogin: demo.vpn\npass: Demo-Vpn-1`, null);
    assert.equal(card.vpn.server, "198.51.100.10", `сервер — из IP1, а не слово из пояснения: ${line}`);
    assert.equal(card.vpn.login, "demo.vpn", line);
    assert.equal(card.vpn.password, "Demo-Vpn-1", line);
  }
});

test("Router без логина: пара с пустым логином, подпись router; по-русски «Роутер»", () => {
  const en = access.buildCard(rec(), "Router\npass: Demo-R-5", null);
  assert.equal(en.vpn, null);
  assert.equal(en.rdp, null);
  assert.deepEqual(flat(en.accounts), ["router|—|Demo-R-5"]);
  assert.deepEqual(flat(access.buildCard(rec(), "Роутер\nпароль: Demo-R-6", null).accounts), ["router|—|Demo-R-6"]);
});

test("форма row 40: три пары «Логин/Пароль» — все три в учётках, шаг RDP — только адрес и «одной из учёток ниже»", () => {
  const text = [
    "Лаборатория · Адрес основной / резервный 192.0.2.40 · Логин: oper.one · Пароль: Demo-One-1",
    "Логин: oper.two · Пароль: Demo-Two-2",
    "Логин: oper.three · Пароль: Demo-Three-3",
  ].join("\n");
  const card = access.buildCard(rec({ method: "rdp", id: "192.0.2.40", tags: ["Рег", "RDP"] }), text, null);
  assert.equal(card.rdp.address, "192.0.2.40");
  assert.equal(card.rdp.login, null, "из трёх пар шаг не выбирает одну");
  assert.equal(card.rdp.password, null);
  assert.equal(card.rdp.useAccountsBelow, true);
  assert.deepEqual(flat(card.accounts), ["windows|oper.one|Demo-One-1", "windows|oper.two|Demo-Two-2", "windows|oper.three|Demo-Three-3"]);
});

test("«Учётка Server — …»: учётка из колонок получает подпись server; без такой строки — windows", () => {
  const text = "Учётка Server — логин: Администратор · пароль: Demo-Srv-9\nRDP — IP: 10.1.1.1";
  const card = access.buildCard(rec({ method: "rdp", id: "", account: "Администратор" }), text, "Demo-Srv-9");
  assert.deepEqual(flat(card.accounts), ["server|Администратор|Demo-Srv-9"], "та же пара в колонках и в «Доступе» — одна учётка");
  assert.equal(card.accounts[0].source, "columns");
  assert.deepEqual(flat(access.buildCard(rec({ account: "Администратор" }), "AnyDesk: 123", "Demo-W-1").accounts), ["windows|Администратор|Demo-W-1"]);
});

test("все формы пар из п. 2.3 ТЗ находятся и подписаны Windows", () => {
  const forms = [
    ["login: alpha / pass: Demo-A-1", "alpha", "Demo-A-1"],
    ["Логин: beta · Пароль: Demo-B-2", "beta", "Demo-B-2"],
    ["User: gamma\nPassword: Demo-C-3", "gamma", "Demo-C-3"],
    ["delta — Demo-D-4", "delta", "Demo-D-4"],
  ];
  for (const [text, login, pass] of forms) {
    assert.deepEqual(flat(access.buildCard(rec(), text, null).accounts), [`windows|${login}|${pass}`], text.replace(/\n/g, "⏎"));
  }
});

test("чего нет в файле — того нет в карточке", () => {
  const empty = access.buildCard(rec(), null, null);
  assert.equal(empty.vpn, null);
  assert.equal(empty.rdp, null);
  assert.deepEqual(empty.accounts, []);
  const programs = access.buildCard(rec(), "AnyDesk: 987 654 321\nLOCAL IP: 10.0.0.9", null);
  assert.equal(programs.vpn, null);
  assert.equal(programs.rdp, null);
  assert.deepEqual(programs.accounts, []);
  assert.equal(access.buildCard(rec(), "Логин: only.login", null).accounts[0]?.password ?? null, null);
});

test("«Доступ · как в файле»: пароли и ключи под маской, логин виден", () => {
  const masked = access.maskSecrets("login: demo · pass: Demo-Visible-1 · L2tpPsk: Demo-Psk-2\nпароль: Demo-Ru-3");
  for (const s of ["Demo-Visible-1", "Demo-Psk-2", "Demo-Ru-3"]) assert.ok(!masked.includes(s), s);
  assert.ok(masked.includes("login: demo"));
  assert.ok(masked.includes("••••"));
});

// ---------- 3. Секреты в окно не приходят ----------

test("publicCard: ни пароля, ни ключа, ни логина-пары в окне; секрет выдаётся по id (👁/⧉) основному процессу", () => {
  const text = "VPN\nIP1: 198.51.100.10\nL2tpPsk: Demo-Psk-001\nlogin: demo.vpn\npass: Demo-VpnPass-1\n\nRDP\nIP: 10.9.8.7\nlogin: demo.rdp\npass: Demo-RdpPass-2\n\nRouter\npass: Demo-RouterPass-3";
  const record = rec({ method: "rdp", id: "", tags: ["VPN", "RDP"], account: "Администратор" });
  const card = access.buildCard(record, text, "Demo-Win-1");
  const pub = access.publicCard(record, card);
  const json = JSON.stringify(pub);
  for (const secret of ["Demo-Psk-001", "Demo-VpnPass-1", "Demo-RdpPass-2", "Demo-RouterPass-3", "Demo-Win-1"]) {
    assert.ok(!json.includes(secret), `в окне нет «${secret}»`);
  }
  assert.equal(pub.vpn.hasKey, true);
  assert.equal(pub.vpn.hasPassword, true);
  assert.equal(pub.rdp.hasPassword, true);
  // Правка разработчика (fix2): id учётки — стабильный «account.<хэш подписи и логина>.<n>», а не индекс «account.N».
  const [win, router] = pub.accounts.map((a) => a.id);
  for (const id of [win, router]) assert.match(id, /^account\.[0-9a-f]{12}\.\d+$/);
  assert.equal(access.cardSecret(card, "vpn.key"), "Demo-Psk-001");
  assert.equal(access.cardSecret(card, "vpn.password"), "Demo-VpnPass-1");
  assert.equal(access.cardSecret(card, "rdp.password"), "Demo-RdpPass-2");
  assert.equal(access.cardSecret(card, win), "Demo-Win-1");
  assert.equal(access.cardSecret(card, router), "Demo-RouterPass-3");
  assert.equal(access.cardSecret(card, "account.0"), null, "старый индексный id больше не работает");
  assert.equal(access.cardSecret(card, "account.000000000000.9"), null);
  assert.equal(access.cardSecret(card, "access"), null, "произвольный id не выдаёт ничего");
  for (const ok of ["vpn.key", "vpn.password", "rdp.password", win, "account.0123456789ab.12"]) assert.ok(access.CARD_SECRETS.test(ok), ok);
  for (const bad of ["password", "account.", "account.0", "account.1x", "../account.1", "vpn.login", "account.0123456789ab.1234", "account.0123456789AB.1"]) {
    assert.ok(!access.CARD_SECRETS.test(bad), bad);
  }
});

// ---------- 1. Фильтр ----------

test("фильтр: чипы — все, программы и «Другое»; RDP, VPN и «Другое» уходят в «Другое»", () => {
  assert.deepEqual(lists.FILTERS, ["all", "anyDesk", "teamViewer", "other"]);
  const records = [
    rec({ sourceRow: 2, program: "anyDesk", id: "111" }),
    rec({ sourceRow: 3, program: "teamViewer", id: "222" }),
    rec({ sourceRow: 4, method: "rdp", id: "10.0.0.4", tags: ["RDP"] }),
    rec({ sourceRow: 5, method: "vpn", id: "10.0.0.5", tags: ["VPN"] }),
    rec({ sourceRow: 6, method: "other", id: "" }),
    rec({ sourceRow: 7, program: "teamViewer", id: "333", tags: ["Рег", "VPN"] }),
  ];
  const rows = (filter) => lists.buildListing({ search: new ConnectionSearch(records), query: "", filter, defaultProgram: "anyDesk", favorites: [], recents: [] })
    .rows.map((r) => r.record.sourceRow).sort((a, b) => a - b);
  assert.deepEqual(rows("all"), [2, 3, 4, 5, 6, 7]);
  assert.deepEqual(rows("anyDesk"), [2]);
  assert.deepEqual(rows("teamViewer"), [3, 7], "TeamViewer с меткой VPN остаётся в TeamViewer");
  assert.deepEqual(rows("other"), [4, 5, 6]);
  const counts = lists.buildListing({ search: new ConnectionSearch(records), query: "", filter: "all", defaultProgram: "anyDesk", favorites: [], recents: [] }).counts;
  assert.deepEqual({ all: counts.all, other: counts.other, anyDesk: counts.anyDesk, teamViewer: counts.teamViewer }, { all: 6, other: 3, anyDesk: 1, teamViewer: 2 });
  assert.ok(!("rdp" in counts) && !("vpn" in counts), "отдельных счётчиков RDP и VPN нет");
});

test("запись без программы и без способа идёт в программу по умолчанию (в ТЗ — «Другое»): расхождение зафиксировано", () => {
  const r = rec({ sourceRow: 8, id: "444" });
  assert.equal(lists.matchesFilter(r, "other", "anyDesk"), false);
  assert.equal(lists.matchesFilter(r, "anyDesk", "anyDesk"), true);
});

// ---------- 4. Номер и звонок ----------

test("нормализация номера → +380XXXXXXXXX и tel:", () => {
  const ok = [
    ["050 000 00 01", "+380500000001"], ["(050) 000-00-01", "+380500000001"], ["050-000-00-01", "+380500000001"],
    ["0500000001", "+380500000001"], ["+380 50 000 00 01", "+380500000001"], ["+38 (050) 000 00 01", "+380500000001"],
    ["380500000001", "+380500000001"], ["80500000001", "+380500000001"], ["  067 000 00 02 ", "+380670000002"],
    ["\u00A0093\u00A0000\u00A000\u00A003", "+380930000003"], ["+48 123 456 789", "+48123456789"],
  ];
  for (const [raw, want] of ok) {
    assert.equal(access.dialable(raw), want, raw);
    assert.equal(access.telURL(raw), `tel:${want}`, raw);
  }
  for (const raw of ["", "   ", "каб. 12", "12-34", "abc", "05000", null, undefined]) {
    assert.equal(access.dialable(raw), null, String(raw));
    assert.equal(access.telURL(raw), null);
  }
  assert.ok(access.isPhone("050 000 00 01"));
  assert.ok(!access.isPhone("050 000 00 01; rm -rf /"), "в звонок попадают только цифры и знаки номера");
  assert.ok(!access.isPhone("tel:+380500000001"));
});

test("контакты: должность из нескольких строк — одна; без телефона — пустой список телефонов", () => {
  const contacts = access.parseContacts([
    "Заступник директора", "вірусологічного відділу", "Демо Іван Петрович", "050 000 00 01, 067 000 00 02", "", "Секретар", "Демо Марія",
  ].join("\n"));
  assert.equal(contacts.length, 2);
  assert.equal(contacts[0].title, "Заступник директора вірусологічного відділу");
  assert.deepEqual(contacts[0].phones, ["050 000 00 01", "067 000 00 02"]);
  assert.deepEqual(contacts[1].phones, [], "«Телефона в файле нет»");
  assert.equal(contacts[1].title, "Секретар");
});

test("звонок: план — только через UniTalk или копирование (1:1 с Mac PhoneCall.plan)", () => {
  assert.deepEqual(dialer.callPlan("050 000 00 01", true), { call: "tel:+380500000001" });
  assert.deepEqual(dialer.callPlan("050 000 00 01", false), { copy: "050 000 00 01", reason: "noUniTalk" });
  assert.deepEqual(dialer.callPlan("каб. 12", true), { copy: "каб. 12", reason: "notANumber" });
  assert.deepEqual(dialer.callPlan(" 050 000 00 01 ", false), { copy: "050 000 00 01", reason: "noUniTalk" });
});

test("обработчик tel:/callto: — по реестру, только чтение; UniTalk распознан, остальные и странные ProgId — нет", async () => {
  const UC = (s) => `HKCU\\Software\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\${s}\\UserChoice`;
  const lookup = (reg) => {
    const calls = [];
    const execFile = (file, args, opts, cb) => {
      calls.push({ file: path.win32.basename(file), args });
      const v = reg[args[1]];
      setImmediate(() => (v == null ? cb(new Error("нет ключа"), "") : cb(null, `\r\n${args[1]}\r\n    x    REG_SZ    ${v}\r\n`)));
    };
    return { calls, ...dialer.createHandlerLookup(execFile) };
  };
  const uni = lookup({ [UC("tel")]: "UniTalk.tel", "HKCR\\UniTalk.tel\\shell\\open\\command": "\"C:\\Demo\\UniTalk\\UniTalk.exe\" \"%1\"" });
  assert.equal(await uni.isUniTalk(), true);
  const store = lookup({ [UC("tel")]: "AppX0demo0uni0talk", "HKCR\\AppX0demo0uni0talk\\shell\\open\\command": "" });
  assert.equal(await store.isUniTalk(), false, "ProgId из Store без «unitalk» в имени — запасной путь (копирование)");
  const other = lookup({ [UC("tel")]: "ChromeHTML", "HKCR\\ChromeHTML\\shell\\open\\command": "chrome.exe %1" });
  assert.equal(await other.isUniTalk(), false);
  assert.equal(await lookup({ [UC("tel")]: "bad\\..\\key" }).isUniTalk(), false);
  assert.equal(await lookup({}).isUniTalk(), false, "нет обработчика");
  assert.equal(await dialer.createHandlerLookup(null).isUniTalk(), false);
  for (const l of [uni, store, other]) {
    assert.ok(l.calls.length > 0);
    for (const c of l.calls) {
      assert.equal(c.file, "reg.exe");
      assert.equal(c.args[0], "query", "только чтение реестра");
      assert.ok(!c.args.some((a) => /^\/?(add|delete|import)$/i.test(a)));
    }
  }
});
