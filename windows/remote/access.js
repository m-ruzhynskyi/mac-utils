// Карточка подключения v2 из «Доступа» и колонок учётки: шаги «Как подключиться» (VPN, затем RDP) и учётные записи; контакты,
// номер для звонка. 1:1 с Mac (`AccessParser.swift`). Разбор — подсказка, а не истина: что не разобралось, остаётся в «Доступе ·
// как в файле»; чего в файле нет — того в карточке нет. Пароли и ключи — только в основном процессе: окну уходит карточка без них
// (publicCard), значение — по 👁 или ⧉ отдельным запросом (файл читается заново).
"use strict";

const crypto = require("node:crypto");
const { isValidHost } = require("./rdp");
const { needsVPN, usesRDP } = require("./models");

const MASK = "••••••";
// Метки паролей и ключей (1:1 с Mac `AccessParser.mask`); всё после них до конца строки уходит под маску («Password: a · b · c» —
// все три). Длинные варианты раньше коротких: «password» раньше «pass». Сразу за меткой — пробел, «:», «=» или тире: «с общим
// ключом.» в пояснении — не значение. Разделитель — «:», «=», тире или пробелы; символы самого значения (в том числе ведущий «-») —
// под маской.
const SECRET_LABEL = new RegExp("(?<![\\p{L}\\d])(парол\\p{L}*|ключ\\p{L}*|секрет\\p{L}*|токен\\p{L}*|пін|пин|"
  + "password|passwort|passphrase|passwd|pass|pwd|pw|l2tp ?psk|pre-?shared[ -]?key|psk|private ?key|key|"
  + "secret|token|pin)(?![\\p{L}\\d])([ \\t]*[:=—–][ \\t]*|[ \\t]+-[ \\t]+|[ \\t]+)(\\S[^\\n]*)", "giu");

// Строка «Доступа»: всё после метки пароля, ключа или PSK до конца строки заменено точками.
// «логин admin · пароль: Qw3rty · ещё» → «логин admin · пароль: ••••••».
const maskSecrets = (line) => String(line).replace(SECRET_LABEL, (_, label, sep) => `${label}${sep}${MASK}`);

// ---------- разбор ----------

// Метки полей (нижний регистр, отдельным словом). Длинные раньше коротких.
const LABELS = [
  ["backup", ["ip2", "запасной", "запасний", "резервный", "резервний", "backup"]],
  ["server", ["ip1", "ip", "адрес", "адреса", "address", "host", "хост", "сервер", "server"]],
  ["port", ["порт", "port"]],
  ["key", ["l2tppsk", "l2tp psk", "pre-shared key", "preshared key", "общий ключ", "загальний ключ", "psk", "ключ", "key"]],
  ["password", ["password", "passwd", "пароля", "пароль", "pass", "pwd"]],
  ["login", ["username", "користувач", "пользователь", "логин", "логін", "login", "user"]],
];
const LABEL_WORDS = new Set(LABELS.flatMap(([, names]) => names));
const VPN_KINDS = ["WireGuard", "PPTP", "L2TP", "FortiClient", "OpenVPN", "IPsec", "IKEv2", "SoftEther"];

const isWordChar = (ch) => !!ch && /[\p{L}\p{N}]/u.test(ch);
const words = (text) => new Set(String(text).toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean));
function mentionsVPN(text) {
  const w = words(text);
  return w.has("vpn") || w.has("впн") || VPN_KINDS.some((k) => w.has(k.toLowerCase()));
}

// Слово в начале строки, с которого начинается блок.
function header(word) {
  const w = String(word).toLowerCase();
  if (w === "vpn" || w === "впн" || VPN_KINDS.some((k) => k.toLowerCase() === w)) return "vpn";
  if (w === "rdp" || w === "рдп") return "rdp";
  if (w === "router" || w === "роутер" || w === "маршрутизатор") return "router";
  if (w === "server" || w === "сервер") return "server";
  if (w === "anydesk" || w === "teamviewer" || w === "rustdesk") return "program";
  return null;
}

const firstWord = (line) => (String(line).match(/^[^\s:—–\-/·|(]*/) || [""])[0];

// Заголовок блока в начале строки и остаток строки после него. «Server»/«Сервер» — заголовок, только если за ним конец строки,
// тире или «/» («Server: 10.0.0.1» — адрес, а не блок). null — не заголовок.
function headed(line) {
  const word = firstWord(line);
  const section = word && header(word);
  if (!section) return null;
  const after = line.slice(word.length);
  const next = after.trimStart()[0];
  if (section === "server" && next && !"—–-/".includes(next)) return null;
  const rest = after.replace(/^[\s:—–\-/·|]+/, "");
  // «Роутер — VPN PPTP · IP: …» — это VPN.
  if ((section === "router" || section === "server") && mentionsVPN(rest)) return { section: "vpn", rest };
  return { section, rest };
}

// Части строки: «·» и «|». Внутри части «;», «,» и « / » могут быть в самом пароле — по ним не делим.
const segments = (text) => String(text).split(/[·|]/).map((s) => s.trim()).filter(Boolean);

// IPv4[:порт] или имя вида host.domain[:порт] (с буквой); null — не адрес.
function host(token) {
  const t = String(token).replace(/^[:—–\-.]+|[:—–\-.]+$/g, "");
  if (/^(\d{1,3}\.){3}\d{1,3}(:\d{1,5})?$/.test(t)) return t;
  if (/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:\d{1,5})?$/.test(t) && /[A-Za-z]/.test(t)) return t;
  return null;
}
function firstHost(text) {
  for (const token of String(text).split(/[ |·,;()]+/)) { const h = host(token); if (h) return h; }
  return null;
}

// Пары { field, value, explicit, at } в части строки, в порядке строки. Разделитель — «:», «=», тире; срезается только он, символы
// значения — нет. Пароль и ключ — вся часть после разделителя (до «·», «|» или конца строки: «ab;cd», «ab, cd», «-Qw1» — целиком),
// остальное — первое слово. Без разделителя — только одно слово в конце короткой части («user ivan»): иначе «логин и пароль в
// колонках» дал бы логин «и», а «…при недоступности первого адреса второй» — сервер «второй».
function labelled(part) {
  const out = [], lower = part.toLowerCase(), taken = [];
  const wordCount = part.split(/\s+/).filter(Boolean).length;
  for (const [field, names] of LABELS) {
    let done = false;
    for (const name of names) {
      let from = 0, at;
      while ((at = lower.indexOf(name, from)) >= 0) {
        const end = at + name.length;
        from = end;
        if (taken.some(([a, b]) => at < b && end > a)) continue;
        if (isWordChar(lower[at - 1]) || isWordChar(lower[end])) continue;
        const afterSpace = part.slice(end).replace(/^[ \t]+/, "");
        const separated = !!afterSpace && (":=—–".includes(afterSpace[0]) || (afterSpace[0] === "-" && afterSpace[1] === " "));
        // Только сам разделитель: «: », «= », « — ».
        let body = (separated ? afterSpace.slice(1) : afterSpace).replace(/^[ \t]+/, "");
        let tokens = body.split(" ").filter(Boolean);
        // «IP: IP: 10.0.0.1» — повтор метки пропускаем.
        while (tokens.length && tokens[0].endsWith(":") && names.includes(tokens[0].slice(0, -1).toLowerCase())) {
          tokens.shift();
          body = body.replace(/^\S*\s*/, "");
        }
        if (!tokens[0]) continue;
        if (!separated && (tokens.length > 1 || wordCount > 3)) continue;
        const secret = field === "password" || field === "key";
        const value = secret ? body.trim() : tokens[0].replace(/[,;]+$/, "");
        if (!value) continue;
        taken.push([at, end]);
        out.push({ field, value, explicit: separated, at: end });
        done = true;
        break;
      }
      if (done) break;
    }
  }
  // В порядке строки: «login: a / pass: b» — сначала логин, потом пароль к нему.
  return out.sort((a, b) => a.at - b.at);
}

// Только цифры (с пробелами, «+ ( ) -»), 7 и больше: телефон или ID.
const looksLikeNumber = (s) => /^[\d+()\- ]+$/.test(s) && (s.match(/\d/g) || []).length >= 7;

// «<логин> — <пароль>». «Пароль» из одних цифр (7 и больше) — номер или ID, не пароль. strict — блок без заголовка: true — строка
// из одной этой части, тогда «пароль» должен быть похож на пароль (от 4 символов, с цифрой или знаком: «Принтер — HP», «Склад —
// касса» — не учётки); null — строка из нескольких частей: пары нет (row 39).
function dashPair(part, strict = false) {
  if (strict === null) return null;
  const w = part.split(" ").filter(Boolean);
  if (w.length !== 3 || !["—", "–", "-"].includes(w[1])) return null;
  const ok = (x) => !header(x) && !host(x) && !x.includes(":") && !LABEL_WORDS.has(x.toLowerCase());
  if (!ok(w[0]) || !ok(w[2]) || looksLikeNumber(w[2])) return null;
  if (strict && (w[2].length < 4 || /^\p{L}+$/u.test(w[2]))) return null;
  return { login: w[0], password: w[2] };
}

// serverExplicit — сервер задан явной меткой с разделителем («IP1:», «Сервер:»): найденное в прозе его не заменяет.
function newBlock(section) { return { section, pairs: [], server: null, serverExplicit: false, backup: null, key: null, port: null, kinds: [], notes: [] }; }
function addLogin(block, login) {
  const last = block.pairs[block.pairs.length - 1];
  if (last && last.login == null && last.password == null) last.login = login; else block.pairs.push({ login, password: null });
}
function addPassword(block, password) {
  const last = block.pairs[block.pairs.length - 1];
  if (last && last.password == null) last.password = password; else block.pairs.push({ login: null, password });
}

function read(text, block, isHeader) {
  const lower = text.toLowerCase();
  if (block.section === "vpn") {
    for (const kind of VPN_KINDS) {
      if (!block.kinds.includes(kind) && new RegExp(`(?<![\\p{L}\\d])${kind.toLowerCase()}`, "u").test(lower)) block.kinds.push(kind);
    }
  }
  const parts = segments(text);
  let used = false;
  parts.forEach((part, i) => {
    const found = labelled(part);
    for (const { field, value, explicit } of found) {
      if (field === "login") addLogin(block, value);
      else if (field === "password") addPassword(block, value);
      else if (field === "key") block.key ??= value;
      else if (field === "server") {
        // Сервер и адрес — только хост (IP или имя с точкой): «второй» из пояснения — не сервер.
        const h = host(value);
        if (h && explicit && !block.serverExplicit) { block.server = h; block.serverExplicit = true; }
        else if (h && block.server == null) block.server = h;
      }
      else if (field === "backup") { const h = host(value); if (h) block.backup ??= h; }
      else if (field === "port") { if (block.port == null && /^\d+$/.test(value)) block.port = value; }
    }
    if (found.length) { used = true; return; }
    // «<логин> — <пароль>»: только в начале строки; в блоке без заголовка — строже (см. dashPair).
    const strict = block.section !== "none" ? false : parts.length === 1 ? true : null;
    const pair = i === 0 ? dashPair(part, strict) : null;
    if (pair) { block.pairs.push(pair); used = true; return; }
    if (block.section === "vpn" || block.section === "rdp") {
      const h = firstHost(part);
      if (h) { block.server ??= h; used = true; }
    }
  });
  // Пояснение VPN — строка из четырёх слов и больше, где ничего не разобралось, или такая часть строки-заголовка
  // («VPN — 203.0.113.10 · подключение средствами Windows…»). Пароли в нём — под маской.
  if (block.section !== "vpn") return;
  const long = (t) => t.split(" ").filter(Boolean).length >= 4;
  if (!used) { if (long(text)) block.notes.push(maskSecrets(text)); }
  else if (isHeader) {
    for (const part of parts) if (!labelled(part).length && !firstHost(part) && !dashPair(part) && long(part)) block.notes.push(maskSecrets(part));
  }
}

// Блоки «Доступа»: группы строк между пустыми строками; строка с заголовком (VPN, RDP, Router, Server, FortiClient…) начинает новый
// блок и без пустой строки.
function blocksOf(text) {
  const result = [];
  let current = null, serverLine = false;
  const close = () => { if (current) result.push(current); current = null; };
  for (const raw of String(text || "").split(/\r\n|[\n\r\v\f\u0085\u2028\u2029]/)) {
    const line = raw.trim();
    if (!line) { close(); continue; }
    // «Учётка Server — логин и пароль в колонках…»: учётка из колонок — от сервера; сама строка — пояснение.
    if (/^уч[её]тк\p{L}*\s+server(?![\p{L}\d])/iu.test(line)) { serverLine = true; continue; }
    let body = line, isHeader = false;
    const h = headed(line);
    if (h) {
      close();
      current = newBlock(h.section);
      body = h.rest; isHeader = true;
      const kind = VPN_KINDS.find((k) => k.toLowerCase() === firstWord(line).toLowerCase());
      if (h.section === "vpn" && kind) current.kinds.push(kind);
    } else if (!current || current.section === "none") {
      // Без заголовка: строка, где VPN или RDP упомянуты посередине, тоже открывает блок.
      const vpn = mentionsVPN(line);
      if (vpn || words(line).has("rdp")) {
        if (current && current.pairs.length) close();
        current = newBlock(vpn ? "vpn" : "rdp");
      }
    }
    if (!current) current = newBlock("none");
    read(body, current, isHeader);
  }
  close();
  return { blocks: result, serverLine };
}

const pairKey = (p) => `${p.login ?? "\u0000"}\u0001${p.password ?? "\u0000"}`;

// Карточка записи (с паролями — только для основного процесса). access — текст «Доступа» (null — нет); accountPassword — пароль
// из колонки (null — нет). { vpn: {kind, server, backupServer, key, login, password, note} | null,
// rdp: {address, login, password, useAccountsBelow} | null, accounts: [{kind, source, login, password}] }.
function buildCard(record, access, accountPassword) {
  const { blocks, serverLine } = blocksOf(access || "");
  const card = { vpn: null, rdp: null, accounts: [] };
  const accessAccounts = [], stepPairs = [];
  const first = (list, f) => { for (const b of list) if (b[f] != null) return b[f]; return null; };

  const vpnBlocks = blocks.filter((b) => b.section === "vpn");
  if (vpnBlocks.length || needsVPN(record)) {
    const kinds = vpnBlocks.flatMap((b) => b.kinds);
    const v = { kind: null, server: first(vpnBlocks, "server"), backupServer: first(vpnBlocks, "backup"), key: first(vpnBlocks, "key"),
      login: null, password: null, note: null };
    const kind = kinds.find((k) => k !== "IPsec") || kinds[0];
    if (kind) v.kind = kind === "L2TP" && (v.key != null || kinds.includes("IPsec")) ? "L2TP/IPsec" : kind;
    const pairs = vpnBlocks.flatMap((b) => b.pairs);
    if (pairs.length) { v.login = pairs[0].login; v.password = pairs[0].password; stepPairs.push(pairs[0]); }
    for (const p of pairs.slice(1)) accessAccounts.push({ kind: "vpn", source: "access", login: p.login, password: p.password });
    const notes = vpnBlocks.flatMap((b) => b.notes);
    if (notes.length) v.note = notes.join(" ");
    card.vpn = v;
  }

  const rdpBlocks = blocks.filter((b) => b.section === "rdp");
  const rdpPairs = rdpBlocks.flatMap((b) => b.pairs);
  if (rdpBlocks.length || usesRDP(record)) {
    const r = { address: null, login: null, password: null, useAccountsBelow: false };
    if (record.method === "rdp" && record.id) r.address = record.id;
    else {
      let a = first(rdpBlocks, "server");
      const port = first(rdpBlocks, "port");
      if (a && !a.includes(":") && port) a += `:${port}`;
      r.address = a;
    }
    if (rdpPairs.length === 1) { r.login = rdpPairs[0].login; r.password = rdpPairs[0].password; stepPairs.push(rdpPairs[0]); }
    card.rdp = r;
  }
  if (rdpPairs.length > 1) for (const p of rdpPairs) accessAccounts.push({ kind: "windows", source: "access", login: p.login, password: p.password });
  for (const b of blocks) {
    const kind = { none: "windows", server: "server", router: "router" }[b.section];
    if (!kind) continue;
    for (const p of b.pairs) accessAccounts.push({ kind, source: "access", login: p.login, password: p.password });
  }

  const accounts = [];
  if (record.account || accountPassword != null) {
    accounts.push({ kind: serverLine ? "server" : "windows", source: "columns", login: record.account || null, password: accountPassword ?? null });
  }
  // Пары из шагов и уже показанные — повторно не выводятся.
  const seen = new Set([...stepPairs, ...accounts].map(pairKey));
  for (const a of accessAccounts) { const k = pairKey(a); if (!seen.has(k)) { seen.add(k); accounts.push(a); } }
  card.accounts = accounts;
  // «Войдите одной из учёток ниже» — только про учётки входа на компьютер (Windows, Server), не роутер и не VPN.
  const logins = accounts.filter((a) => a.kind === "windows" || a.kind === "server").length;
  if (card.rdp && card.rdp.login == null && card.rdp.password == null && logins > 1) card.rdp.useAccountsBelow = true;
  return card;
}

// Все значения, которые карточка считает секретами: пароли, ключ, пароли учёток (для маски «Доступа» по значению).
const cardSecrets = (card) => [card.vpn?.key, card.vpn?.password, card.rdp?.password, ...card.accounts.map((a) => a.password)].filter((v) => v != null);

const isPlainWord = (w) => {
  const bare = w.replace(/:$/, "");
  return !!w && !w.includes(MASK) && !header(bare) && !host(w) && !LABEL_WORDS.has(bare.toLowerCase());
};
const isWordCh = (ch) => ch != null && /[\p{L}\p{N}]/u.test(ch);
// Значение отдельным словом (по краям — не буква и не цифра) — точками.
function replaceWord(value, line) {
  let out = "", rest = line, at;
  while ((at = rest.indexOf(value)) >= 0) {
    const bounded = !isWordCh(rest[at - 1]) && !isWordCh(rest[at + value.length]);
    out += rest.slice(0, at) + (bounded ? MASK : value);
    rest = rest.slice(at + value.length);
  }
  return out + rest;
}
// Одиночные слова после «·»/«|», пароль в «слово — слово», строка из одного слова.
function maskLoosePieces(line) {
  const trimmed = line.trim();
  if (!/\s/.test(trimmed) && isPlainWord(trimmed)) return line.replace(trimmed, MASK);
  // «VPN Qw1» (row 13): заголовок блока, пробел и одно слово — больше ничего. Слово может быть паролем — как «RDP — Qw1».
  const two = trimmed.split(/\s+/);
  if (two.length === 2 && header(two[0]) && header(two[0]) !== "program" && isPlainWord(two[1])) return line.replace(two[1], MASK);
  const pieces = line.split(/([·|])/);
  let index = 0;
  return pieces.map((piece) => {
    if (piece === "·" || piece === "|") return piece;
    const words = piece.trim().split(" ").filter(Boolean);
    let res = piece;
    if (index > 0 && words.length === 1 && isPlainWord(words[0])) res = piece.replace(words[0], MASK);
    else if (words.length === 3 && ["—", "–", "-"].includes(words[1]) && isPlainWord(words[2])) {
      const lead = piece.match(/^ */)[0], tail = piece.match(/ *$/)[0];
      res = `${lead}${words[0]} ${words[1]} ${MASK}${tail}`;
    }
    index++;
    return res;
  }).join("");
}

// «Доступ · как в файле» для показа (1:1 с Mac `AccessParser.masked`). Под маской: всё после метки пароля, ключа или PSK до конца
// строки; каждое значение из secrets (пароли и ключи карточки, пароль ID, пароли учёток) отдельным словом; «пароль» в форме «слово —
// слово»; одиночные слова без метки после «·»/«|» и строки из одного слова, кроме заголовков блоков и адресов. Логины в таких местах
// тоже закрываются: лучше спрятать лишнее, чем показать пароль.
function maskedAccess(text, secrets = []) {
  const values = [...new Set(secrets.map((v) => String(v).trim()).filter(Boolean))].sort((a, b) => b.length - a.length);
  return String(text || "").split("\n").map((raw) => {
    const cr = raw.endsWith("\r");
    let line = maskSecrets(cr ? raw.slice(0, -1) : raw);
    for (const v of values) line = replaceWord(v, line);
    line = maskLoosePieces(line);
    return cr ? `${line}\r` : line;
  }).join("\n");
}

// Стабильные id учёток: «account.<хэш подписи и логина>.<номер среди одинаковых>». Карточка перестраивается из файла на каждый 👁/⧉;
// индекс в списке после правки файла указал бы на соседнюю учётку, а такой id — на ту же или ни на какую. Хэш — не логин: в журнал
// и окно сам логин через id не попадает (логин окно и так показывает).
function accountIds(accounts) {
  const seen = new Map();
  return accounts.map((a) => {
    const h = crypto.createHash("sha256").update(`${a.kind}\u0001${a.login ?? ""}`).digest("hex").slice(0, 12);
    const n = seen.get(h) || 0;
    seen.set(h, n + 1);
    return `account.${h}.${n}`;
  });
}

// Карточка для окна: без паролей и ключей — только признаки и id секрета для 👁/⧉ (vpn.key, vpn.password, rdp.password,
// account.<хэш>.<n>). Адрес RDP из «Доступа» помечен fromAccess: окно его обратно не передаёт — файл читается заново.
function publicCard(record, card) {
  const out = { vpn: null, rdp: null, accounts: [] };
  if (card.vpn) {
    const { kind, server, backupServer, login, note } = card.vpn;
    out.vpn = { kind, server, backupServer, login, note, hasKey: card.vpn.key != null, hasPassword: card.vpn.password != null };
  }
  if (card.rdp) {
    const { address, login, useAccountsBelow } = card.rdp;
    out.rdp = { address, login, useAccountsBelow, hasPassword: card.rdp.password != null, canOpen: !!address && isValidHost(address),
      fromAccess: !(record.method === "rdp" && record.id) && !!address };
  }
  const ids = accountIds(card.accounts);
  out.accounts = card.accounts.map((a, i) => ({ id: ids[i], kind: a.kind, source: a.source, login: a.login, hasPassword: a.password != null }));
  return out;
}

// Учётка с таким id есть в карточке (после перечитывания файла её может не быть).
const hasAccount = (card, id) => accountIds(card.accounts).includes(id);
// Значение секрета карточки по id; null — нет такого (или у учётки нет пароля).
function cardSecret(card, id) {
  if (id === "vpn.key") return card.vpn?.key ?? null;
  if (id === "vpn.password") return card.vpn?.password ?? null;
  if (id === "rdp.password") return card.rdp?.password ?? null;
  const i = ACCOUNT_ID.test(id) ? accountIds(card.accounts).indexOf(id) : -1;
  return i >= 0 ? card.accounts[i].password ?? null : null;
}
const ACCOUNT_ID = /^account\.[0-9a-f]{12}\.\d{1,3}$/;
const CARD_SECRETS = /^(vpn\.key|vpn\.password|rdp\.password|account\.[0-9a-f]{12}\.\d{1,3})$/;

// ---------- контакты ----------

const PHONE = /\+?\(?\d[\d \t ()\-]{5,}\d/g;
function phoneRanges(line) {
  const out = [];
  for (const m of String(line).matchAll(PHONE)) {
    const raw = m[0], text = raw.trim();
    if ((text.match(/\d/g) || []).length >= 7) out.push({ start: m.index, end: m.index + raw.length, text });
  }
  return out;
}
// Телефоны в «Контактах»: цифры с «+ ( ) -» и пробелами, не меньше 7 цифр; перенос строки телефон не продолжает.
const findPhones = (text) => String(text || "").split(/\r\n|\n|\r/).flatMap((l) => phoneRanges(l).map((p) => p.text));

// Контакты по строкам: [{title, detail, phones}]. Строка с маленькой буквы продолжает предыдущую («Заступник директора» +
// «вірусологічного відділу» — одна должность). Контакт заканчивается телефоном или пустой строкой; текст перед телефоном — его
// подпись, после последнего телефона строки — пояснение («каб. 12»).
function parseContacts(text) {
  const lines = [];
  for (const raw of String(text || "").split(/\r\n|\n|\r/)) {
    const line = raw.trim();
    if (!line) { lines.push(null); continue; }
    const prev = lines[lines.length - 1];
    if (prev && !phoneRanges(prev).length && /^\p{Ll}/u.test(line)) lines[lines.length - 1] = `${prev} ${line}`;
    else lines.push(line);
  }
  const clean = (s) => s.replace(/^[ ,;:—–\-·|\t]+|[ ,;:—–\-·|\t]+$/g, "").replace(/\s{2,}/g, " ");
  const contacts = [];
  let pending = [];
  const flush = () => {
    if (!pending.length) return;
    contacts.push({ title: pending[0], detail: pending.slice(1).join(" ") || null, phones: [] });
    pending = [];
  };
  for (const line of lines) {
    if (line == null) { flush(); continue; }
    const found = phoneRanges(line);
    if (!found.length) { pending.push(line); continue; }
    let cursor = 0;
    for (const m of found) {
      const label = clean(line.slice(cursor, m.start));
      cursor = m.end;
      if (label) pending.push(label);
      if (!pending.length && contacts.length) { contacts[contacts.length - 1].phones.push(m.text); continue; }   // второй номер того же человека
      contacts.push({ title: pending[0] || "", detail: pending.slice(1).join(" ") || null, phones: [m.text] });
      pending = [];
    }
    const tail = clean(line.slice(cursor));
    if (tail && contacts.length) { const c = contacts[contacts.length - 1]; c.detail = [c.detail, tail].filter(Boolean).join(" · "); }
  }
  flush();
  return contacts;
}

// Телефон годится для копирования и звонка (строка из окна): только цифры, «+ ( ) -» и пробелы, 7–20 цифр.
function isPhone(text) {
  const s = String(text ?? "");
  const digits = (s.match(/\d/g) || []).length;
  return s.length <= 40 && /^[+\d ()\- ]+$/.test(s) && digits >= 7 && digits <= 20;
}

// Номер для звонка в виде +380XXXXXXXXX: «050 000 00 01» → «+380500000001». null — не похоже на украинский номер; другие страны
// с «+» — как есть, только цифры. 1:1 с Mac (`PhoneNumber.dialable`).
function dialable(raw) {
  const s = String(raw ?? "");
  let digits = s.replace(/\D/g, ""), plus = s.trim().startsWith("+");
  // «00380…» — международный префикс вместо «+».
  if (!plus && digits.startsWith("00")) { digits = digits.slice(2); plus = true; }
  // С кодом Украины — ровно 12 цифр: «+380 50 000 00 01 1» не номер.
  if (digits.startsWith("380") && digits.length !== 12 && (plus || digits.length > 12)) return null;
  if (digits.length === 12 && digits.startsWith("380")) return `+${digits}`;
  if (digits.length === 11 && digits.startsWith("80")) return `+3${digits}`;
  if (digits.length === 10 && digits.startsWith("0")) return `+38${digits}`;
  if (digits.length === 9 && !digits.startsWith("0")) return `+380${digits}`;
  if (plus && digits.length >= 8 && digits.length <= 15) return `+${digits}`;
  return null;
}
const telURL = (raw) => { const n = dialable(raw); return n ? `tel:${n}` : null; };

module.exports = { maskSecrets, maskedAccess, cardSecrets, buildCard, publicCard, cardSecret, hasAccount, accountIds, ACCOUNT_ID, CARD_SECRETS, blocksOf, labelled, dashPair, host, VPN_KINDS,
  parseContacts, findPhones, isPhone, dialable, telURL };
