// Где ещё лежит AnyDesk/TeamViewer, кроме Program Files (только чтение, rc-win-entry B). Чаще всего AnyDesk на Windows
// запускают без установки: AnyDesk.exe (или «AnyDesk (1).exe») лежит в «Загрузках» или на Рабочем столе. Ещё — обработчик
// ссылок `anydesk:` / `teamviewer10:` / `tvcontrol1:` и App Paths из реестра (`reg query`, ничего не пишется) и путь
// запущенного процесса. Папки смотрятся при каждом вопросе (это быстро), реестр и процессы — асинхронно, по refresh().
"use strict";

const path = require("node:path");

const REG = path.win32.join(process.env.SystemRoot || "C:\\Windows", "System32", "reg.exe");
const POWERSHELL = path.win32.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
const TIMEOUT_MS = 5000;

// Имя файла программы: «AnyDesk.exe», «AnyDesk (1).exe», «AnyDesk-portable.exe»; «TeamViewer.exe», «TeamViewer_Setup.exe» — нет
// (установщик), «TeamViewerQS.exe» — да (QuickSupport тоже подключается).
const FILE = {
  anyDesk: /^AnyDesk[^\\/]*\.exe$/i,
  teamViewer: /^TeamViewer(?!_?Setup)[^\\/]*\.exe$/i,
};
const SCHEMES = { anyDesk: ["anydesk"], teamViewer: ["teamviewer10", "tvcontrol1"] };
const APP_PATHS = { anyDesk: "AnyDesk.exe", teamViewer: "TeamViewer.exe" };
const PROCESS = { anyDesk: "AnyDesk", teamViewer: "TeamViewer" };

// Путь файла подходит программе (по имени файла).
const isProgramFile = (program, file) => !!FILE[program] && FILE[program].test(path.win32.basename(String(file || "")));

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

// deps: { fs, env, execFile } — в тестах двойники (фейковая ФС и реестр). execFile null — реестр и процессы не смотрим.
function createLocator({ fs, env = process.env, execFile = null, reg = REG, powershell = POWERSHELL, timeoutMs = TIMEOUT_MS } = {}) {
  const fromSystem = { anyDesk: [], teamViewer: [] };
  const exists = (file) => { try { return fs.existsSync(file); } catch (_) { return false; } };
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
        let mtime = 0;
        try { const st = fs.statSync(file); if (!st.isFile()) continue; mtime = st.mtimeMs || 0; } catch (_) { continue; }
        found.push({ file, mtime });
      }
    }
    return found.sort((a, b) => b.mtime - a.mtime).map((f) => f.file);
  }

  const run = (file, args) => new Promise((resolve) => {
    if (typeof execFile !== "function") return resolve(null);
    try {
      execFile(file, args, { windowsHide: true, timeout: timeoutMs, encoding: "utf8" }, (err, stdout) => resolve(err ? null : String(stdout || "")));
    } catch (_) { resolve(null); }
  });
  const query = async (key) => regValue(await run(reg, ["query", key, "/ve"]));

  // Реестр: обработчик ссылок (пользователь, затем машина) и App Paths; затем путь запущенного процесса.
  async function systemCandidates(program) {
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
    // Запущенный процесс (портативный AnyDesk, открытый не из «Загрузок»): только путь exe, без параметров. PowerShell — только
    // если ни папки, ни реестр ничего не дали.
    if (out.some(exists) || inFolders(program).length) return [...new Set(out)].filter((f) => isProgramFile(program, f));
    const ps = await run(powershell, ["-NoProfile", "-NonInteractive", "-Command",
      `Get-Process -Name '${PROCESS[program]}*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Path }`]);
    for (const line of String(ps || "").split(/\r?\n/)) if (line.trim()) out.push(line.trim());
    return [...new Set(out)].filter((f) => isProgramFile(program, f));
  }

  return {
    // Кандидаты по порядку: папки пользователя, затем найденное в реестре и процессах (по последнему refresh()).
    candidates(program) { return [...new Set([...inFolders(program), ...(fromSystem[program] || [])])]; },
    // Перечитать реестр и процессы. Возвращает true, если что-то поменялось.
    async refresh() {
      let changed = false;
      for (const program of Object.keys(fromSystem)) {
        let list = [];
        try { list = await systemCandidates(program); } catch (_) { list = []; }
        if (list.join("|") !== fromSystem[program].join("|")) { fromSystem[program] = list; changed = true; }
      }
      return changed;
    },
  };
}

module.exports = { createLocator, commandExe, regValue, isProgramFile, FILE, SCHEMES };
