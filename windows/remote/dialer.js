// Звонок через UniTalk (Windows): чей обработчик у `tel:`/`callto:` — по реестру, только чтение (`reg query`): выбор пользователя
// HKCU\…\UrlAssociations\<схема>\UserChoice (ProgId → команда HKCR\<ProgId>\shell\open\command), иначе HKCR\<схема>\shell\open\command.
// Обработчик — UniTalk: shell.openExternal('tel:+380…'). Иначе номер копируется. В реестр ничего не пишется; номер в журнал — нет.
"use strict";

const path = require("node:path");
const { telURL } = require("./access");

const REG = path.win32.join(process.env.SystemRoot || "C:\\Windows", "System32", "reg.exe");
const SCHEMES = ["tel", "callto"];
const TIMEOUT_MS = 5000;

// Значение из вывода `reg query … /v ProgId` или `/ve`: «    (Default)    REG_SZ    "C:\…\UniTalk.exe" "%1"».
function regValue(output) {
  const m = /REG_(?:EXPAND_)?SZ[ \t]+(.*)$/m.exec(String(output || ""));
  return m ? m[1].trim() : null;
}

// execFile — child_process.execFile (в тестах двойник). Возвращает { handler(scheme) → Promise<string|null>, isUniTalk() → Promise<boolean> }.
function createHandlerLookup(execFile, { reg = REG, timeoutMs = TIMEOUT_MS } = {}) {
  const query = (key, args) => new Promise((resolve) => {
    if (typeof execFile !== "function") return resolve(null);
    try {
      execFile(reg, ["query", key, ...args], { windowsHide: true, timeout: timeoutMs, encoding: "utf8" },
        (err, stdout) => resolve(err ? null : regValue(stdout)));
    } catch (_) { resolve(null); }
  });
  // Команда обработчика схемы: «ProgId → команда» или ProgId сам по себе (у приложений из Store команды в HKCR может не быть).
  async function handler(scheme) {
    const progId = await query(`HKCU\\Software\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\${scheme}\\UserChoice`, ["/v", "ProgId"]);
    if (progId && /^[\w.\-]+$/.test(progId)) {
      const command = await query(`HKCR\\${progId}\\shell\\open\\command`, ["/ve"]);
      return [progId, command].filter(Boolean).join(" ");
    }
    return query(`HKCR\\${scheme}\\shell\\open\\command`, ["/ve"]);
  }
  async function isUniTalk() {
    for (const scheme of SCHEMES) {
      const h = await handler(scheme);
      if (h && /unitalk/i.test(h)) return true;
    }
    return false;
  }
  return { handler, isUniTalk };
}

// План звонка (1:1 с Mac `PhoneCall.plan`): { call: "tel:+380…" } или { copy: номер, reason: "noUniTalk" | "notANumber" }.
function callPlan(raw, uniTalk) {
  const number = String(raw ?? "").trim();
  const url = telURL(number);
  if (!url) return { copy: number, reason: "notANumber" };
  return uniTalk ? { call: url } : { copy: number, reason: "noUniTalk" };
}

module.exports = { createHandlerLookup, callPlan, regValue, REG, SCHEMES };
