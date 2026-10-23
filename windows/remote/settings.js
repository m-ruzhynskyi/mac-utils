// Настройки модуля: только путь, лист, программа по умолчанию, клавиша, таймаут, флаги, избранное и недавние ПО ID.
// Паролей здесь нет и быть не должно (ни файла, ни реестра, ни TEMP). Файл — в папке данных приложения.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { PROGRAMS } = require("./models");

const DEFAULTS = Object.freeze({
  file: "",              // путь к .xlsx/.xml
  sheet: "",             // лист .xlsx; пусто — первый
  defaultProgram: "anyDesk",
  hotkey: "Ctrl+Alt+A",
  timeoutSeconds: 20,    // ожидание окна пароля
  autoLogin: false,      // отметка «входить автоматически» (AnyDesk)
  notify: true,          // уведомление после подключения
  programPaths: { anyDesk: "", teamViewer: "" },   // путь к программе, если не в стандартном месте
  favoriteIDs: [],
  recentIDs: [],
});

const str = (value, fallback) => (typeof value === "string" ? value : fallback);
const ids = (list) => (Array.isArray(list) ? list.filter((x) => typeof x === "string" && /^[A-Za-z0-9._@-]{1,64}$/.test(x)).slice(0, 500) : []);

// Любые данные → допустимые настройки (так читается файл и применяется обновление).
function normalize(raw) {
  raw = raw && typeof raw === "object" ? raw : {};
  const timeout = Number(raw.timeoutSeconds);
  return {
    file: str(raw.file, DEFAULTS.file),
    sheet: str(raw.sheet, DEFAULTS.sheet),
    defaultProgram: PROGRAMS.includes(raw.defaultProgram) ? raw.defaultProgram : DEFAULTS.defaultProgram,
    hotkey: str(raw.hotkey, DEFAULTS.hotkey) || DEFAULTS.hotkey,
    timeoutSeconds: Number.isFinite(timeout) && timeout > 0 ? Math.min(120, Math.max(5, Math.round(timeout))) : DEFAULTS.timeoutSeconds,
    autoLogin: raw.autoLogin === true,
    notify: raw.notify !== false,
    programPaths: { anyDesk: str(raw.programPaths?.anyDesk, ""), teamViewer: str(raw.programPaths?.teamViewer, "") },
    favoriteIDs: ids(raw.favoriteIDs),
    recentIDs: ids(raw.recentIDs).slice(0, 5),
  };
}

class RemoteSettings {
  constructor(file) {
    this.file = file;
    let raw = {};
    try { raw = JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) {}
    this.data = normalize(raw);
  }

  get favoriteIDs() { return this.data.favoriteIDs; }
  set favoriteIDs(list) { this.data.favoriteIDs = ids(list); this.save(); }
  get recentIDs() { return this.data.recentIDs; }
  set recentIDs(list) { this.data.recentIDs = ids(list).slice(0, 5); this.save(); }

  // Частичное обновление (только известные поля); возвращает текущие настройки.
  update(patch) {
    this.data = normalize({ ...this.data, ...patch, programPaths: { ...this.data.programPaths, ...(patch?.programPaths || {}) } });
    this.save();
    return this.data;
  }

  // Атомарная запись рядом: временный файл → переименование.
  save() {
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      const tmp = `${this.file}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2), { encoding: "utf8", mode: 0o600 });
      fs.renameSync(tmp, this.file);
    } catch (_) {}
  }
}

module.exports = { RemoteSettings, DEFAULTS, normalize };
