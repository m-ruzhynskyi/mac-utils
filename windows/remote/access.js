// «Как подключиться» из текста «Доступа» (строки про VPN и RDP) и телефоны из «Контактов». 1:1 с Mac (`AccessParser.swift`).
// Разбор — подсказка, а не истина: что не разобралось, показывается строками «Доступа» по «Показать», значения паролей и ключей
// в них — под маской (maskSecrets, ещё в основном процессе). Пароль или ключ VPN наружу из
// основного процесса не уходит: окну — только признак «есть», копируется он отдельным запросом (файл читается заново).
"use strict";

const { isValidHost } = require("./rdp");

const VPN_KINDS = ["WireGuard", "PPTP", "L2TP", "FortiClient", "OpenVPN", "IPsec", "IKEv2", "SoftEther"];
const SERVER_LABELS = ["сервер", "server", "адрес", "address", "host", "ip"];
const LOGIN_LABELS = ["логин", "логін", "login", "user", "користувач", "пользователь"];
const SECRET_LABELS = ["пароль", "password", "pass", "ключ", "key", "l2tppsk", "psk", "secret"];
const PORT_LABELS = ["порт", "port"];
const isLetter = (ch) => !!ch && /\p{L}/u.test(ch);

// Непустые строки без пробелов по краям.
const linesOf = (text) => String(text || "").split(/\r\n|[\n\r\v\f\u0085\u2028\u2029]/).map((l) => l.trim()).filter(Boolean);

// Значение после метки: «логин: admin», «Login — admin», «пароль admin123» (до «·», «|», «;», запятой, пробела или конца строки).
// Метка — отдельным словом; берётся её первое вхождение в части строки (как на Mac).
function valueAfter(labels, lines) {
  for (const line of lines) {
    for (const part of line.split(/[·|;]/)) {
      const p = part.trim(), lower = p.toLowerCase();
      for (const label of labels) {
        const at = lower.indexOf(label);
        if (at < 0) continue;
        const end = at + label.length;
        if (isLetter(lower[at - 1]) || isLetter(lower[end])) continue;
        // Разделители — только в начале: «=» в конце — часть ключа (base64 у WireGuard), его не срезаем.
        const rest = p.slice(end).replace(/^[ :=—–\-\t]+/, "").trimEnd();
        const word = rest.split(/[ ,]/).find((w) => w) || "";
        if (word) return word;
      }
    }
  }
  return null;
}

const MASK = "••••••";
// Метки паролей и ключей (1:1 с Mac `AccessParser.mask`); значение после них до «·», «|», «;» или конца строки уходит под маску.
// Длинные варианты раньше коротких: «password» раньше «pass».
const SECRET_LABEL = new RegExp("(?<![\\p{L}\\d])(парол\\p{L}*|ключ\\p{L}*|секрет\\p{L}*|токен\\p{L}*|пін|пин|"
  + "password|passwort|passphrase|passwd|pass|pwd|pw|l2tp ?psk|pre-?shared[ -]?key|psk|private ?key|key|"
  + "secret|token|pin)(?![\\p{L}\\d])([\\s:=—–\\-]*)([^\\s·|;:=—–\\-](?:[^·|;\\n]*[^\\s·|;\\n])?)", "giu");

// Строка «Доступа» для окна: значения после меток пароля, ключа и PSK заменены точками.
// «пароль: Qw3rty · логин admin» → «пароль: •••••• · логин admin».
const maskSecrets = (line) => String(line).replace(SECRET_LABEL, (_, label, sep) => `${label}${sep}${MASK}`);

// IPv4[:порт] или имя вида host.domain[:порт] (с буквой); null — не адрес.
function host(token) {
  const t = String(token).replace(/^[:—–\-.]+|[:—–\-.]+$/g, "");
  if (/^(\d{1,3}\.){3}\d{1,3}(:\d{1,5})?$/.test(t)) return t;
  if (/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:\d{1,5})?$/.test(t) && /[A-Za-z]/.test(t)) return t;
  return null;
}

function firstHost(lines) {
  for (const line of lines) for (const token of line.split(/[ |·,;()]+/)) { const h = host(token); if (h) return h; }
  return null;
}

// text — «Доступ» целиком. { vpn: {kind, server, login, secret, lines} | null, rdp: {address, login, lines} | null };
// lines — строки про VPN/RDP с паролями и ключами под маской.
function parseAccess(text) {
  const lines = linesOf(text);
  const info = { vpn: null, rdp: null };
  const vpnLines = lines.filter((line) => { const l = line.toLowerCase(); return l.includes("vpn") || VPN_KINDS.some((k) => l.includes(k.toLowerCase())); });
  if (vpnLines.length) {
    const joined = vpnLines.join("\n").toLowerCase();
    info.vpn = {
      kind: VPN_KINDS.find((k) => joined.includes(k.toLowerCase())) || null,
      server: valueAfter(SERVER_LABELS, vpnLines) || firstHost(vpnLines),
      login: valueAfter(LOGIN_LABELS, vpnLines),
      secret: valueAfter(SECRET_LABELS, vpnLines),
      lines: vpnLines.map(maskSecrets),
    };
  }
  const rdpLines = lines.filter((line) => { const l = line.toLowerCase(); return l.includes("rdp") || l.includes("remote desktop"); });
  if (rdpLines.length) {
    const labelled = valueAfter(SERVER_LABELS, rdpLines);
    let address = (labelled && host(labelled)) || firstHost(rdpLines);
    if (address && !address.includes(":")) {
      const port = (valueAfter(PORT_LABELS, rdpLines) || "").match(/^\d+/);
      if (port) address = `${address}:${port[0]}`;
    }
    info.rdp = { address: address || null, login: valueAfter(LOGIN_LABELS, rdpLines), lines: rdpLines.map(maskSecrets) };
  }
  return info;
}

// Блок «Как подключиться» для окна: без пароля или ключа VPN (только признак). record — запись (method, id, account, needsVPN/usesRDP);
// info — parseAccess(…) или null (нет «Доступа»). Не разобралось — строки «Доступа» про VPN/RDP с маской паролей (lines).
function howToConnect(record, info, { needsVPN = false, usesRDP = false } = {}) {
  const out = { vpn: null, rdp: null };
  const vpn = info && info.vpn, rdp = info && info.rdp;
  if (needsVPN || vpn) {
    const parsed = !!vpn && !!(vpn.server || vpn.login || vpn.secret);
    out.vpn = { kind: (vpn && vpn.kind) || null, server: parsed ? vpn.server || null : null, login: parsed ? vpn.login || null : null,
      hasSecret: parsed && !!vpn.secret, lines: !parsed && vpn ? vpn.lines.slice() : [] };
  }
  if (usesRDP || rdp) {
    const address = record.method === "rdp" && record.id ? record.id : (rdp && rdp.address) || null;
    out.rdp = { address, login: record.account || (rdp && rdp.login) || null, canOpen: !!address && isValidHost(address),
      fromAccess: !(record.method === "rdp" && record.id) && !!address, lines: !address && rdp ? rdp.lines.slice() : [] };
  }
  return out;
}

// Телефоны в «Контактах»: цифры с «+ ( ) -» и пробелами, не меньше 7 цифр; перенос строки телефон не продолжает.
function findPhones(text) {
  const found = [];
  for (const m of String(text || "").matchAll(/\+?\(?\d[\d \t\u00A0()\-]{5,}\d/g)) {
    const s = m[0].trim();
    if ((s.match(/\d/g) || []).length >= 7) found.push(s);
  }
  return found;
}

// Телефон годится для копирования (строка из окна): только цифры, «+ ( ) -» и пробелы, 7–20 цифр.
function isPhone(text) {
  const s = String(text ?? "");
  const digits = (s.match(/\d/g) || []).length;
  return s.length <= 40 && /^[+\d ()\-\u00A0]+$/.test(s) && digits >= 7 && digits <= 20;
}

module.exports = { parseAccess, howToConnect, maskSecrets, findPhones, isPhone, valueAfter, host, VPN_KINDS };
