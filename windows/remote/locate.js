// Где ещё лежит AnyDesk/TeamViewer, кроме Program Files (только чтение, rc-win-entry B), и можно ли этому файлу верить.
// Чаще всего AnyDesk на Windows запускают без установки: AnyDesk.exe (или «AnyDesk (1).exe») лежит в «Загрузках» или на
// Рабочем столе. Ещё — обработчик ссылок `anydesk:` / `teamviewer10:` / `tvcontrol1:` и App Paths из реестра (`reg query`,
// ничего не пишется) и путь запущенного процесса.
// Пароль получает только программа, которой можно верить (ревью rc-win-entry, FIX 1): файл в Program Files (туда пишет только
// администратор) или файл с действительной подписью Authenticode издателя программы (AnyDesk Software GmbH / philandro Software
// GmbH; TeamViewer Germany GmbH / TeamViewer GmbH). Подпись проверяет PowerShell (`Get-AuthenticodeSignature`); путь уходит ему
// через stdin (UTF-8), не в строку команды. Итог хранится по пути и времени изменения файла.
"use strict";

const path = require("node:path");

const REG = path.win32.join(process.env.SystemRoot || "C:\\Windows", "System32", "reg.exe");
const POWERSHELL = path.win32.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
const TIMEOUT_MS = 5000;
const SIGNATURE_TIMEOUT_MS = 15_000;

// Имя файла программы — по списку разрешённых форм, а не по началу имени: «AnyDesk.exe», «AnyDesk (1).exe», «AnyDesk-portable.exe»,
// «TeamViewer.exe», «TeamViewer (2).exe». Установщики, деинсталляторы, MSI, службы (`TeamViewer_Service`, `_Desktop`,
// `_Assignment`), `Host_Setup`, «crack» и QuickSupport (`TeamViewerQS` — только принимающая сторона, исходящее подключение не
// начинает) — нет.
const FILE = {
  anyDesk: /^AnyDesk(?:[ ._-]?portable)?(?: ?\(\d{1,3}\))?\.exe$/i,
  teamViewer: /^TeamViewer(?:[ ._-]?portable)?(?: ?\(\d{1,3}\))?\.exe$/i,
};
const SCHEMES = { anyDesk: ["anydesk"], teamViewer: ["teamviewer10", "tvcontrol1"] };
const APP_PATHS = { anyDesk: "AnyDesk.exe", teamViewer: "TeamViewer.exe" };
const PROCESS = { anyDesk: "AnyDesk", teamViewer: "TeamViewer" };
// Издатели (CN или O сертификата подписи).
const PUBLISHERS = {
  anyDesk: ["AnyDesk Software GmbH", "philandro Software GmbH"],
  teamViewer: ["TeamViewer Germany GmbH", "TeamViewer GmbH"],
};

// Проверка подписи: команда — константа, путь — первой строкой stdin в UTF-8 (иначе кириллица в имени папки ломается).
// Ответ — одна строка «Статус|Subject сертификата».
const SIGNATURE_COMMAND = [
  "$ErrorActionPreference = 'Stop'",
  "[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)",
  "$in = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))",
  "$p = $in.ReadLine()",
  "try { $s = Get-AuthenticodeSignature -LiteralPath $p; [Console]::Out.WriteLine(([string]$s.Status) + '|' + [string]$s.SignerCertificate.Subject) }",
  "catch { [Console]::Out.WriteLine('Error|') }",
].join("; ");

// Путь файла подходит программе (по имени файла).
const isProgramFile = (program, file) => !!FILE[program] && FILE[program].test(path.win32.basename(String(file || "")));

// Subject сертификата → поля: «CN=AnyDesk Software GmbH, O=AnyDesk Software GmbH, L=Stuttgart, C=DE» → { CN, O, L, C }.
function subjectFields(subject) {
  const out = {};
  for (const part of String(subject || "").split(/,\s*(?=[A-Za-z.]+=)/)) {
    const m = /^([A-Za-z.]+)=(.*)$/.exec(part.trim());
    if (m) out[m[1].toUpperCase()] = m[2].trim().replace(/^"(.*)"$/, "$1");
  }
  return out;
}

// Ответ проверки подписи: действительна и выдана издателю программы.
function signatureOK(program, output) {
  const line = String(output || "").split(/\r?\n/).find((l) => l.includes("|")) || "";
  const [status, ...rest] = line.split("|");
  if (status.trim() !== "Valid") return false;
  const fields = subjectFields(rest.join("|"));
  const allowed = (PUBLISHERS[program] || []).map((p) => p.toLowerCase());
  return [fields.CN, fields.O].some((v) => v && allowed.includes(v.toLowerCase()));
}

// Путь exe из команды обработчика: «"C:\…\AnyDesk.exe" "%1"», «C:\…\AnyDesk.exe %1», «C:\…\AnyDesk.exe --url "%1"».
function commandExe(command) {
  const s = String(command || "").trim();
  const quoted = /^"([^"]+\.exe)"/i.exec(s);
  if (quoted) return quoted[1];
  const bare = /^(.+?\.exe)(?=\s|$)/i.exec(s);
  return bare ? bare[1] : null;
}

// Значение из вывода `reg query … /ve`: «    (Default)    REG_SZ    "C:\…\AnyDesk.exe" "%1"».
function regValue(output) {
  const m = /REG_(?:EXPAND_)?SZ[ \t]+(.*)$/m.exec(String(output || ""));
  return m ? m[1].trim() : null;
}

// Файл — в Program Files (туда пишет только администратор): ему верим без проверки подписи. %LOCALAPPDATA%, «Загрузки»,
// Рабочий стол и прочее — только с подписью.
function inProgramFiles(file, env = process.env) {
  const norm = (p) => path.win32.normalize(String(p)).toLowerCase().replace(/\\+$/, "") + "\\";
  const target = path.win32.normalize(String(file || "")).toLowerCase();
  if (!path.win32.isAbsolute(target)) return false;
  return [env.ProgramFiles || "C:\\Program Files", env["ProgramFiles(x86)"] || "C:\\Program Files (x86)", env.ProgramW6432]
    .filter(Boolean).some((root) => target.startsWith(norm(root)));
}

// deps: { fs, env, execFile } — в тестах двойники (фейковая ФС, реестр, PowerShell). execFile null — реестр, процессы и подписи не
// смотрим (тогда вне Program Files ничему не верим).
function createLocator({ fs, env = process.env, execFile = null, reg = REG, powershell = POWERSHELL, timeoutMs = TIMEOUT_MS } = {}) {
  const fromRegistry = { anyDesk: [], teamViewer: [] };
  const fromProcess = { anyDesk: [], teamViewer: [] };
  const signatures = new Map();   // «программа|путь|mtime» → true/false
  const exists = (file) => { try { return fs.existsSync(file); } catch (_) { return false; } };
  const mtime = (file) => { try { return fs.statSync(file).mtimeMs || 0; } catch (_) { return -1; } };
  const expand = (p) => String(p).replace(/%([^%]+)%/g, (all, name) => env[name] ?? all);

  // «Загрузки» и Рабочий стол (и Рабочий стол в OneDrive): файлы программы, новые первыми.
  function folders() {
    const home = env.USERPROFILE || "";
    return [home && path.win32.join(home, "Downloads"), home && path.win32.join(home, "Desktop"),
      env.OneDrive && path.win32.join(env.OneDrive, "Desktop")].filter(Boolean);
  }
  function inFolders(program) {
    const found = [];
    for (const dir of folders()) {
      let names = [];
      try { names = fs.readdirSync(dir); } catch (_) { continue; }
      for (const name of names) {
        if (!isProgramFile(program, name)) continue;
        const file = path.win32.join(dir, name);
        let time = 0;
        try { const st = fs.statSync(file); if (!st.isFile()) continue; time = st.mtimeMs || 0; } catch (_) { continue; }
        found.push({ file, time });
      }
    }
    return found.sort((a, b) => b.time - a.time).map((f) => f.file);
  }

  // stdin — текст первой строкой (путь для проверки подписи); без него вход закрывается сразу.
  const run = (file, args, stdin = null, limitMs = timeoutMs) => new Promise((resolve) => {
    if (typeof execFile !== "function") return resolve(null);
    try {
      const child = execFile(file, args, { windowsHide: true, timeout: limitMs, encoding: "utf8" }, (err, stdout) => resolve(err ? null : String(stdout || "")));
      try { child?.stdin?.end?.(stdin == null ? "" : Buffer.from(`${stdin}\n`, "utf8")); } catch (_) {}
    } catch (_) { resolve(null); }
  });
  const query = async (key) => regValue(await run(reg, ["query", key, "/ve"]));

  // Реестр: обработчик ссылок (пользователь, затем машина) и App Paths.
  async function registryCandidates(program) {
    const out = [];
    for (const scheme of SCHEMES[program]) {
      for (const root of ["HKCU\\Software\\Classes", "HKCR"]) {
        const exe = commandExe(expand(await query(`${root}\\${scheme}\\shell\\open\\command`) || ""));
        if (exe) out.push(exe);
      }
    }
    for (const root of ["HKCU", "HKLM"]) {
      const exe = commandExe(expand(await query(`${root}\\Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\${APP_PATHS[program]}`) || ""));
      if (exe) out.push(exe);
    }
    return [...new Set(out)].filter((f) => isProgramFile(program, f));
  }
  // Запущенный процесс (портативный AnyDesk, открытый не из «Загрузок»): только путь exe. Команда — константа.
  async function processCandidates(program) {
    const ps = await run(powershell, ["-NoProfile", "-NonInteractive", "-Command",
      `Get-Process -Name '${PROCESS[program]}*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Path }`]);
    return [...new Set(String(ps || "").split(/\r?\n/).map((l) => l.trim()).filter(Boolean))].filter((f) => isProgramFile(program, f));
  }

  const key = (program, file) => `${program}|${path.win32.normalize(String(file)).toLowerCase()}|${mtime(file)}`;

  const locator = {
    // Находки вне Program Files по порядку (ревью rc-win-entry, FIX 1, п. 3): реестр и App Paths → «Загрузки» и Рабочий стол →
    // запущенный процесс. Своё и Program Files/%LOCALAPPDATA% connect.js ставит раньше.
    candidates(program) {
      return [...new Set([...(fromRegistry[program] || []), ...inFolders(program), ...(fromProcess[program] || [])])];
    },
    // Верим ли файлу сейчас (без ожидания): Program Files или уже проверенная подпись этого же файла (путь и mtime).
    trusted(program, file) {
      if (!isProgramFile(program, file) && !inProgramFiles(file, env)) return false;
      if (inProgramFiles(file, env)) return true;
      return signatures.get(key(program, file)) === true;
    },
    // Проверить подпись (результат запоминается по пути и mtime). Program Files — без проверки.
    async verify(program, file) {
      if (inProgramFiles(file, env)) return true;
      if (!exists(file)) return false;
      const k = key(program, file);
      if (signatures.has(k)) return signatures.get(k);
      const ok = signatureOK(program, await run(powershell, ["-NoProfile", "-NonInteractive", "-Command", SIGNATURE_COMMAND], String(file), SIGNATURE_TIMEOUT_MS));
      signatures.set(k, ok);
      return ok;
    },
    // Перечитать реестр и процессы и проверить подписи всех находок (и `extra` — свой путь, %LOCALAPPDATA%). true — что-то
    // поменялось (окно перерисует «установлен»).
    async refresh(extra = {}) {
      const checked = signatures.size;
      let changed = false;
      for (const program of Object.keys(fromRegistry)) {
        const before = locator.candidates(program).map((f) => `${f}:${locator.trusted(program, f)}`).join("|");
        try { fromRegistry[program] = await registryCandidates(program); } catch (_) { fromRegistry[program] = []; }
        const known = [...fromRegistry[program], ...inFolders(program)];
        // PowerShell за процессами — только если ни реестр, ни папки ничего не дали.
        try { fromProcess[program] = known.some(exists) ? [] : await processCandidates(program); } catch (_) { fromProcess[program] = []; }
        for (const file of [...(extra[program] || []), ...locator.candidates(program)]) if (file && exists(file)) await locator.verify(program, file);
        if (before !== locator.candidates(program).map((f) => `${f}:${locator.trusted(program, f)}`).join("|")) changed = true;
      }
      return changed || signatures.size !== checked;
    },
  };
  return locator;
}

module.exports = { createLocator, commandExe, regValue, isProgramFile, inProgramFiles, signatureOK, subjectFields, FILE, SCHEMES, PUBLISHERS, SIGNATURE_COMMAND };
