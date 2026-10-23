// Подключение: AnyDesk — CLI (`AnyDesk.exe <ID> --with-password`, пароль через stdin, не в аргументах); TeamViewer — запуск с ID и
// ввод пароля в окно «Аутентификация» через UI Automation (не аргументом), с проверкой процесса и фокуса. Пароль читается из файла
// в момент подключения (SecretBuffer) и затирается в любом исходе; в журнал — только числа и коды. Всё внешнее (запуск процессов,
// UI Automation, окна, часы) — внедряется: тесты идут на двойниках, реальные программы не запускаются.
"use strict";

const path = require("node:path");
const { programOf, TITLES, downloadURL } = require("./models");

// Где ищем программы (если путь не задан в настройках).
function defaultPaths(env = process.env) {
  const pf = env.ProgramFiles || "C:\\Program Files", pf86 = env["ProgramFiles(x86)"] || "C:\\Program Files (x86)", local = env.LOCALAPPDATA || "";
  return {
    anyDesk: [path.win32.join(pf86, "AnyDesk", "AnyDesk.exe"), path.win32.join(pf, "AnyDesk", "AnyDesk.exe"), local && path.win32.join(local, "Programs", "AnyDesk", "AnyDesk.exe")].filter(Boolean),
    teamViewer: [path.win32.join(pf, "TeamViewer", "TeamViewer.exe"), path.win32.join(pf86, "TeamViewer", "TeamViewer.exe")],
  };
}

const MESSAGES = {
  notInstalled: (p) => ({ kind: "danger", title: `${TITLES[p]} не найден`, detail: "Установите программу или укажите путь к ней в настройках.", actions: [{ id: "download", label: `Скачать ${TITLES[p]}` }] }),
  fieldNotFound: (p) => ({ kind: "warning", title: "Введите пароль вручную", detail: `Не нашёл поле пароля в окне ${TITLES[p]}. Пароль не копировался.`, actions: [{ id: "close", label: "Закрыть" }] }),
  wrongPassword: () => ({ kind: "danger", title: "Проверьте пароль в файле", detail: "Программа не приняла пароль.", actions: [{ id: "openFile", label: "Открыть файл" }, { id: "close", label: "Закрыть" }] }),
  focusLost: () => ({ kind: "warning", title: "Ввод прерван", detail: "Фокус ушёл из окна программы. Пароль не введён.", actions: [{ id: "retry", label: "Повторить" }, { id: "close", label: "Закрыть" }] }),
  gone: () => ({ kind: "info", title: "Записи больше нет в файле", detail: "Список обновлён.", actions: [{ id: "close", label: "Закрыть" }] }),
  elevated: (p) => ({ kind: "warning", title: `${TITLES[p]} запущен от администратора`, detail: "Mac Utils не может ввести пароль в его окно (UIPI). Перезапустите программу без прав администратора или введите пароль вручную.", actions: [{ id: "close", label: "Закрыть" }] }),
  launchFailed: (p) => ({ kind: "danger", title: `Не удалось запустить ${TITLES[p]}`, detail: "Программа не приняла команду.", actions: [{ id: "retry", label: "Повторить" }, { id: "close", label: "Закрыть" }] }),
  noPasswordInFile: () => ({ kind: "info", title: "Пароля в файле нет", detail: "Введите пароль вручную.", actions: [{ id: "close", label: "Закрыть" }] }),
};

// deps: { exists(path), env, spawn(file, args, opts), uia: { enter(opts, secret, onEvent) → Promise<result> }, hud: { show(state) }, openExternal(url), log(line) }
function createConnector(deps) {
  const { exists = () => false, customPaths = () => ({}), env = process.env, spawn, uia = null, hud = { show() {} }, openExternal = () => {}, log = () => {}, clock = Date } = deps;
  const defaults = defaultPaths(env);

  function find(program, custom) {
    if (custom && exists(custom)) return custom;
    return defaults[program].find((p) => exists(p)) || null;
  }
  const installed = (program) => !!find(program, customPaths()[program]);

  // AnyDesk: пароль через stdin. Процесс отвязан от нашего: подключение живёт своей жизнью.
  function launchAnyDesk(exe, id, secret) {
    return new Promise((resolve) => {
      let settled = false, payload = null;
      const wipePayload = () => { if (payload) { payload.fill(0); payload = null; } };
      const done = (r) => { if (!settled) { settled = true; wipePayload(); resolve(r); } };
      let child;
      try { child = spawn(exe, secret ? [id, "--with-password"] : [id], { stdio: ["pipe", "ignore", "ignore"], windowsHide: true, detached: true }); }
      catch (_) { return done({ ok: false }); }
      // Обработчики ошибок — до записи: запуск мог не удаться асинхронно (exe заменён обновлением, путь неверен), и запись в stdin
      // без слушателя ошибки уронила бы главный процесс (EPIPE).
      child.on?.("error", () => done({ ok: false }));
      child.stdin?.on?.("error", () => done({ ok: false }));
      child.on?.("exit", (code) => done({ ok: code === 0 || code == null }));
      const finish = () => setTimeout(() => done({ ok: true }), 600);
      if (secret) {
        // Пароль идёт в stdin байтами из буфера (не строкой), потом вход закрывается; копия затирается.
        try {
          payload = Buffer.concat([secret.bytes, Buffer.from("\n")]);
          child.stdin.write(payload, () => { wipePayload(); try { child.stdin.end(); } catch (_) {} finish(); });
        } catch (_) { return done({ ok: false }); }
      } else finish();
      child.unref?.();
    });
  }

  function launchTeamViewer(exe, id) {
    return new Promise((resolve) => {
      let child;
      try { child = spawn(exe, ["-i", id], { stdio: "ignore", windowsHide: false, detached: true }); }
      catch (_) { return resolve(false); }
      child.on?.("error", () => resolve(false));
      setTimeout(() => resolve(true), 400);
      child.unref?.();
    });
  }

  // record — запись; opts: { noPassword, settings, store }. Возвращает {ok, state}.
  async function connectRecord(record, opts) {
    const { noPassword = false, settings, store } = opts;
    const program = programOf(record, settings.defaultProgram);
    const title = TITLES[program];
    const exe = find(program, settings.programPaths?.[program]);
    if (!exe) { hud.show(MESSAGES.notInstalled(program)); log(`connect fail code=notInstalled`); return { ok: false, error: "notInstalled" }; }
    // ID, начинающийся с «-», программа приняла бы за параметр командной строки.
    if (record.id.startsWith("-")) { hud.show(MESSAGES.launchFailed(program)); log(`connect fail code=badID`); return { ok: false, error: "badID" }; }
    hud.show({ kind: "info", title: `Открываю ${title}…`, detail: record.name, spinner: true });

    // Запись и пароль — заново из файла в момент подключения.
    let secret = null;
    try {
      if (!noPassword && record.hasPassword) {
        secret = await store.password(record);
        if (!secret) { hud.show(MESSAGES.noPasswordInFile()); }
      }
    } catch (_) { hud.show(MESSAGES.gone()); log(`connect fail code=gone`); return { ok: false, error: "gone" }; }

    try {
      if (program === "anyDesk") {
        const launched = await launchAnyDesk(exe, record.id, secret);
        if (!launched.ok) { hud.show(MESSAGES.launchFailed(program)); log(`connect fail code=launch program=${program}`); return { ok: false, error: "launch" }; }
        hud.show(secret ? { kind: "success", title: "Пароль передан", detail: `${title} подключается к ${record.name}`, autoHideMs: 2500 }
                        : { kind: "success", title: `Открыт ${title}`, detail: `${record.name}`, autoHideMs: 2500 });
        log(`connect ok program=${program} password=${secret ? 1 : 0}`);
        return { ok: true };
      }
      // TeamViewer
      if (record.id.includes("@")) { hud.show(MESSAGES.launchFailed(program)); return { ok: false, error: "alias" }; }
      if (!secret || !uia) {
        if (!(await launchTeamViewer(exe, record.id))) { hud.show(MESSAGES.launchFailed(program)); log(`connect fail code=launch program=${program}`); return { ok: false, error: "launch" }; }
        if (!secret) { hud.show({ kind: "success", title: `Открыт ${title}`, detail: record.name, autoHideMs: 2500 }); log(`connect ok program=${program} password=0`); return { ok: true }; }
        hud.show(MESSAGES.fieldNotFound(program)); return { ok: false, error: "fieldNotFound" };
      }
      const timeoutMs = Math.max(5, settings.timeoutSeconds || 20) * 1000;
      const started = clock.now();
      // TeamViewer запускается, когда скрипт запомнил уже открытые окна пароля: пароль не уйдёт в окно прежнего подключения.
      let launched = null;
      const result = await uia.enter({ timeoutMs, afterReady: async () => { launched = await launchTeamViewer(exe, record.id); } }, secret, (event) => {
        if (event.state === "waiting") hud.show({ kind: "info", title: "Жду окно пароля…", detail: `${Math.round((clock.now() - started) / 1000)} с`, progress: Math.min(1, (clock.now() - started) / timeoutMs), actions: [{ id: "cancel", label: "Отмена" }] });
      });
      if (launched === false) { hud.show(MESSAGES.launchFailed(program)); log(`connect fail code=launch program=${program}`); return { ok: false, error: "launch" }; }
      switch (result.state) {
        case "entered":
          hud.show({ kind: "success", title: "Пароль введён", detail: `${title} подключается к ${record.name}`, autoHideMs: 2500 }); log(`connect ok program=${program} password=1`); return { ok: true };
        case "noWindow":     // окно пароля не появилось — вход без пароля (сохранённый доступ), ошибки нет
          hud.show({ kind: "success", title: "Подключено", detail: `${record.name} · без пароля`, autoHideMs: 2500 }); log(`connect ok program=${program} password=0 prompt=0`); return { ok: true };
        case "wrongPassword": hud.show(MESSAGES.wrongPassword()); log(`connect fail code=wrongPassword`); return { ok: false, error: "wrongPassword" };
        case "focusLost": hud.show(MESSAGES.focusLost()); log(`connect fail code=focusLost`); return { ok: false, error: "focusLost" };
        case "elevated": hud.show(MESSAGES.elevated(program)); log(`connect fail code=elevated`); return { ok: false, error: "elevated" };
        case "cancelled": hud.show({ kind: "info", title: "Отменено", autoHideMs: 1500 }); return { ok: false, error: "cancelled" };
        default: hud.show(MESSAGES.fieldNotFound(program)); log(`connect fail code=fieldNotFound`); return { ok: false, error: "fieldNotFound" };
      }
    } finally {
      secret?.wipe();      // затирание в любом исходе: ошибка, отмена, таймаут
    }
  }

  // Кнопки тоста.
  function hudAction(id, ctx = {}) {
    if (id === "download" && ctx.program) openExternal(downloadURL(ctx.program));
    if (id === "cancel") uia?.cancel?.();
    return id;
  }

  return { installed, find, connectRecord, hudAction, MESSAGES };
}

module.exports = { createConnector, defaultPaths, MESSAGES };
