// Хранилище списка подключений: путь и лист из настроек, чтение файла, наблюдение за изменениями (правка на месте, замена файла
// Excel или редактором, файла пока нет — следим за папкой), повторы при «занят». 1:1 с Mac (`ConnectionsFileStore`), кроме облака
// macOS (на Windows файл OneDrive скачивается самой системой при чтении).
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { EventEmitter } = require("node:events");
const { kindOf, load, passwordFor, MAX_FILE_SIZE } = require("./source");
const xlsx = require("./xlsx");
const { ConnectionsError } = require("./models");

// Ошибки «файл занят» (Excel сохраняет, антивирус, сеть).
const LOCKED = new Set(["EBUSY", "EPERM", "EACCES", "EAGAIN", "EMFILE"]);

class ConnectionsFileStore extends EventEmitter {
  // timing: debounce 0,5 с, повтор «занят» 2 с ×3, опрос папки 5 с — в тестах короче.
  constructor({ debounceMs = 500, retryMs = 2000, retries = 3, pollMs = 5000 } = {}) {
    super();
    this.timing = { debounceMs, retryMs, retries, pollMs };
    this.file = null;
    this.sheet = null;
    this.state = { status: "noFile", snapshot: null, error: null };
    this.watcher = null;
    this.timers = new Set();
    this.generation = 0;
    this.hadFile = false;
  }

  setSource(file, sheet = null) {
    this.stopWatching();
    this.file = file || null;
    this.sheet = sheet || null;
    this.hadFile = false;
    if (!this.file) return this.set({ status: "noFile", snapshot: null, error: null });
    this.reload();
  }

  stop() { this.generation++; this.stopWatching(); }

  set(state) { this.state = state; this.emit("change", state); }

  // Перечитать сейчас (кнопка «Перечитать», изменение файла).
  reload() {
    if (!this.file) return;
    const generation = ++this.generation;
    this.watch();
    this.set({ ...this.state, status: this.state.snapshot ? this.state.status : "loading" });
    this.read(generation, 0);
  }

  read(generation, attempt) {
    if (generation !== this.generation) return;
    const file = this.file;
    let kind;
    try { kind = kindOf(file); } catch (e) { return this.fail(e); }
    fs.promises.stat(file).then((stat) => {
      if (stat.size > MAX_FILE_SIZE) throw new ConnectionsError("tooLarge");
      return fs.promises.readFile(file);
    }).then((data) => {
      if (generation !== this.generation) return;
      let snapshot;
      try { snapshot = load(data, kind, this.sheet); } catch (e) { return this.fail(e instanceof ConnectionsError ? e : new ConnectionsError("corrupt")); }
      this.hadFile = true;
      this.set({ status: "ready", snapshot, error: null });
    }, (error) => {
      if (generation !== this.generation) return;
      if (error instanceof ConnectionsError) return this.fail(error);
      const gone = error && error.code === "ENOENT";
      // Занят — или файл, который был, пропал на глазах (Excel заменяет файл): подождать и прочитать снова.
      if ((error && LOCKED.has(error.code)) || (gone && this.hadFile)) {
        if (attempt < this.timing.retries) return this.later(() => this.read(generation, attempt + 1), this.timing.retryMs);
        return this.fail(new ConnectionsError(gone ? "unavailable" : "locked"));
      }
      this.fail(new ConnectionsError("unavailable"));
    });
  }

  // Ошибка: прежний список не сохраняется.
  fail(error) { this.set({ status: "error", snapshot: null, error }); }

  later(fn, ms) {
    const timer = setTimeout(() => { this.timers.delete(timer); fn(); }, ms);
    timer.unref?.();
    this.timers.add(timer);
  }

  // Следим за папкой: правка на месте, атомарная замена и появление файла дают событие с его именем.
  watch() {
    if (this.watcher) return;
    const dir = path.dirname(this.file), base = path.basename(this.file).toLowerCase();
    const onEvent = (_event, name) => {
      if (name && String(name).toLowerCase() !== base) return;   // чужие файлы и ~$-временные Excel
      this.debounce();
    };
    try { this.watcher = fs.watch(dir, { persistent: false }, onEvent); this.watcher.on("error", () => this.pollInstead()); }
    catch (_) { this.pollInstead(); }
  }

  // Папки нет или её не отследить (сетевой диск, отключённый том): раз в pollMs смотрим, что с файлом.
  pollInstead() {
    if (this.watcher) { try { this.watcher.close(); } catch (_) {} }
    this.watcher = { close: () => clearInterval(timer) };
    let last = null;
    const timer = setInterval(() => {
      let stamp = "none";
      try { const s = fs.statSync(this.file); stamp = `${s.mtimeMs}:${s.size}`; } catch (_) {}
      if (last !== null && stamp !== last) this.debounce();
      last = stamp;
    }, this.timing.pollMs);
    timer.unref?.();
  }

  debounce() {
    clearTimeout(this.debounceTimer);
    this.debounceTimer = setTimeout(() => this.reload(), this.timing.debounceMs);
    this.debounceTimer.unref?.();
  }

  stopWatching() {
    this.generation++;
    clearTimeout(this.debounceTimer);
    for (const t of this.timers) clearTimeout(t);
    this.timers.clear();
    if (this.watcher) { try { this.watcher.close(); } catch (_) {} this.watcher = null; }
  }

  // Имена листов (для выбора в настройках); только для .xlsx.
  async sheetNames() {
    if (!this.file || kindOf(this.file) !== "xlsx") return [];
    return xlsx.sheetNames(await fs.promises.readFile(this.file));
  }

  // Пароль записи — файл читается заново в момент подключения. SecretBuffer или null (нет записи или пароля).
  async password(record) {
    if (!this.file) return null;
    const data = await fs.promises.readFile(this.file);
    return passwordFor(record, data, kindOf(this.file), this.sheet);
  }
}

module.exports = { ConnectionsFileStore };
