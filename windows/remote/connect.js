// Подключение: AnyDesk — CLI (`AnyDesk.exe <ID> --with-password`, пароль через stdin, не в аргументах); TeamViewer — запуск с ID и
// ввод пароля в окно «Аутентификация» через UI Automation (не аргументом), с проверкой процесса и фокуса. Пароль читается из файла
// в момент подключения (SecretBuffer) и затирается в любом исходе; в журнал — только числа и коды. Всё внешнее (запуск процессов,
// UI Automation, окна, часы, буфер обмена для ID) — внедряется: тесты идут на двойниках, реальные программы не запускаются.
//
// Зелёный «успех» — только подтверждённый сеанс: UI Automation нашёл устоявшееся окно сеанса TeamViewer с ID партнёра (после ввода
// пароля — «Подключено», без пароля — «Подключено без пароля»). Пароль введён, а сеанса нет — «сеанс не подтверждён» (не успех);
// сеанс закрылся — свой исход; окно TeamViewer было, но ни пароля, ни сеанса — «Не удалось подтвердить подключение» (ID в буфер,
// только ID); окон TeamViewer не было вовсе — «TeamViewer не открылся». Пароль TeamViewer читается из файла лениво — только когда
// скрипт нашёл и проверил поле пароля (событие «passwordField»), и сразу затирается.
// AnyDesk через CLI ничего не подтверждает (процесс лишь принял команду): тост нейтральный «Пароль передан» / «Открыт AnyDesk».
// Окно AnyDesk «Terminal Session» на Windows модуль не нажимает: доступа UI Automation к AnyDesk у модуля нет (его окно рисуется
// своим движком, без стандартных элементов) — выбор остаётся за AnyDesk/пользователем, ложного «подключено» при этом не бывает.
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
  // Ни одного окна TeamViewer за срок (служба не в счёт): клиент не открылся. Пароль не вводился.
  noTeamViewerWindow: (p, copied) => ({ kind: "warning", title: `${TITLES[p]} не открылся`, detail: `${TITLES[p]} не показал окон за отведённое время. Пароль не вводился.${copied ? " ID скопирован." : ""}`, actions: [{ id: "retry", label: "Повторить" }, { id: "close", label: "Закрыть" }] }),
  noPasswordInFile: () => ({ kind: "info", title: "Пароля в файле нет", detail: "Введите пароль вручную.", actions: [{ id: "close", label: "Закрыть" }] }),
  // Окно сеанса не найдено и окна пароля не было: подключение не подтверждено. Тост нейтральный, без галочки.
  unconfirmed: (p, copied) => copied
    ? { kind: "info", title: "Не удалось подключиться — ID скопирован", detail: `${TITLES[p]} открыт, но не показал ни окно пароля, ни открытый сеанс. Вставьте ID в ${TITLES[p]} вручную.`, actions: [{ id: "close", label: "Закрыть" }] }
    : { kind: "info", title: "Не удалось подтвердить подключение", detail: `${TITLES[p]} открыт, но не показал ни окно пароля, ни открытый сеанс.`, actions: [{ id: "close", label: "Закрыть" }] },
  // Пароль введён, а окна сеанса к сроку нет: не успех, но и не ошибка — смотреть в окне программы.
  submitted: (p) => ({ kind: "info", title: "Пароль введён · сеанс не подтверждён", detail: `Проверьте окно ${TITLES[p]}: открылся ли сеанс.`, actions: [{ id: "close", label: "Закрыть" }] }),
  sessionClosed: (p) => ({ kind: "warning", title: `${TITLES[p]} закрыл сеанс`, detail: `Пароль введён, но сеанс не открылся. Причина — в окне ${TITLES[p]}.`, actions: [{ id: "retry", label: "Повторить" }, { id: "close", label: "Закрыть" }] }),
  // Окно пароля показывает ID другого компьютера: пароль этой записи туда не вводится.
  idMismatch: (p) => ({ kind: "warning", title: "Окно пароля — от другого компьютера", detail: `${TITLES[p]} показал другой ID. Пароль не вводился.`, actions: [{ id: "close", label: "Закрыть" }] }),
  passwordNeeded: (p) => ({ kind: "info", title: `Введите пароль в окне ${TITLES[p]}`, detail: `${TITLES[p]} спрашивает пароль, а в файле его нет.`, actions: [{ id: "close", label: "Закрыть" }] }),
};

// deps: { exists(path), env, spawn(file, args, opts), uia: { enter(opts, password: async () => SecretBuffer, onEvent) → Promise<result> }, hud: { show(state) }, openExternal(url),
//         log(line), copyText(text) — запасной путь TeamViewer: кладёт в буфер обмена ID (никогда не пароль) }
function createConnector(deps) {
  const { exists = () => false, customPaths = () => ({}), env = process.env, spawn, uia = null, hud = { show() {} }, openExternal = () => {}, log = () => {}, clock = Date, copyText = null } = deps;
  // ID в буфер: только ID записи, только строкой. Нет функции или она упала — честно говорим, что не скопирован.
  const copyID = (id) => { if (typeof copyText !== "function") return false; try { return copyText(String(id)) !== false; } catch (_) { return false; } };
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

    // Запись и пароль — заново из файла в момент подключения. AnyDesk (CLI) нужен пароль сразу; TeamViewer — лишь когда найдено поле.
    const wantsPassword = !noPassword && !!record.hasPassword;
    let secret = null;
    const secrets = [];
    try {
      if (wantsPassword && program === "anyDesk") {
        secret = await store.password(record);
        if (secret) secrets.push(secret); else hud.show(MESSAGES.noPasswordInFile());
      }
    } catch (_) { hud.show(MESSAGES.gone()); log(`connect fail code=gone`); return { ok: false, error: "gone" }; }

    try {
      if (program === "anyDesk") {
        const launched = await launchAnyDesk(exe, record.id, secret);
        if (!launched.ok) { hud.show(MESSAGES.launchFailed(program)); log(`connect fail code=launch program=${program}`); return { ok: false, error: "launch" }; }
        // CLI подтверждает только запуск: подключилось ли (и не ждёт ли AnyDesk выбора «Terminal Session») — не знаем. Не «успех».
        hud.show(secret ? { kind: "info", title: "Пароль передан", detail: `${title} подключается к ${record.name} — дальше в окне ${title}`, autoHideMs: 4000 }
                        : { kind: "info", title: `Открыт ${title}`, detail: `${record.name} — дальше в окне ${title}`, autoHideMs: 4000 });
        log(`connect ok program=${program} password=${secret ? 1 : 0}`);
        return { ok: true };
      }
      // TeamViewer
      if (record.id.includes("@")) { hud.show(MESSAGES.launchFailed(program)); return { ok: false, error: "alias" }; }
      if (!uia) {
        // Без UI Automation подключение не проверить: ID — в буфер на случай, если TeamViewer открылся без него.
        if (!(await launchTeamViewer(exe, record.id))) { hud.show(MESSAGES.launchFailed(program)); log(`connect fail code=launch program=${program}`); return { ok: false, error: "launch" }; }
        if (!wantsPassword) {
          const copied = copyID(record.id);
          hud.show({ kind: "info", title: `Открыт ${title}`, detail: copied ? `${record.name} · ID скопирован — если подключение не началось, вставьте его` : record.name, autoHideMs: 4000 });
          log(`connect ok program=${program} password=0 confirmed=0 copied=${copied ? 1 : 0}`); return { ok: true };
        }
        hud.show(MESSAGES.fieldNotFound(program)); return { ok: false, error: "fieldNotFound" };
      }
      const timeoutMs = Math.max(5, settings.timeoutSeconds || 20) * 1000;
      const started = clock.now();
      // TeamViewer запускается, когда скрипт запомнил уже открытые окна: пароль не уйдёт в окно прежнего подключения, а окно
      // прежнего сеанса не сойдёт за подтверждение нового. ID нужен скрипту для запасного пути (ввести в поле главного окна и нажать
      // «Connect») и чтобы узнать окно сеанса; пароля в параметрах нет.
      let launched = null, typed = false;
      const waiting = (title) => hud.show({ kind: "info", title, detail: `${Math.round((clock.now() - started) / 1000)} с`, progress: Math.min(1, (clock.now() - started) / timeoutMs), actions: [{ id: "cancel", label: "Отмена" }] });
      // Пароль — только по запросу скрипта (поле найдено и проверено); каждая прочитанная копия затирается в finally.
      const readPassword = async () => { const s = await store.password(record); if (s) secrets.push(s); return s; };
      const result = await uia.enter({ timeoutMs, id: record.id, ...(wantsPassword ? {} : { noPassword: true }), afterReady: async () => { launched = await launchTeamViewer(exe, record.id); } },
        wantsPassword ? readPassword : null, (event) => {
        if (event.state === "idSubmitted") { typed = true; waiting(`Ввёл ID в ${title}, жду подключение…`); }
        else if (event.state === "intermediate") waiting(`${title} подключается…`);
        else if (event.state === "confirming") waiting("Пароль введён, жду сеанс…");
        else if (event.state === "waiting") waiting(typed ? `Ввёл ID в ${title}, жду подключение…` : (wantsPassword ? "Жду окно пароля…" : "Жду подключение…"));
      });
      if (launched === false) { hud.show(MESSAGES.launchFailed(program)); log(`connect fail code=launch program=${program}`); return { ok: false, error: "launch" }; }
      const t = typed ? 1 : 0;
      switch (result.state) {
        case "connected":    // пароль введён, и окно сеанса с ID партнёра открылось и устоялось
          hud.show({ kind: "success", title: "Подключено", detail: `${record.name} · сеанс ${title} открыт`, autoHideMs: 2500 }); log(`connect ok program=${program} password=1 confirmed=1 typed=${t}`); return { ok: true };
        case "entered":      // прежний итог скрипта (пароль ушёл, сеанс не проверялся) — не «подключено»
        case "submitted":    // пароль введён, окна сеанса к сроку нет — не успех
          hud.show(MESSAGES.submitted(program)); log(`connect fail code=submitted program=${program} typed=${t}`); return { ok: false, error: "submitted" };
        case "sessionClosed":
          hud.show(MESSAGES.sessionClosed(program)); log(`connect fail code=sessionClosed program=${program} typed=${t}`); return { ok: false, error: "sessionClosed" };
        case "session":      // окно сеанса найдено и устоялось, окна пароля не было — вход без пароля подтверждён
          hud.show({ kind: "success", title: "Подключено без пароля", detail: `${record.name} · сеанс открыт — ${title} пустил без пароля`, autoHideMs: 2500 }); log(`connect ok program=${program} password=0 confirmed=1 typed=${t}`); return { ok: true };
        case "passwordNeeded":   // TeamViewer спрашивает пароль, а в файле его нет (или запись пропала к моменту ввода)
          if (result.secretError) { hud.show(MESSAGES.gone()); log(`connect fail code=gone`); return { ok: false, error: "gone" }; }
          hud.show(MESSAGES.passwordNeeded(program)); log(`connect ok program=${program} password=0 prompt=1 typed=${t}`); return { ok: true };
        case "noPrompt": {   // окно TeamViewer было, но ни окна пароля, ни окна сеанса к сроку — не «подключено»: нейтрально, ID в буфер
          const copied = copyID(record.id);
          hud.show(MESSAGES.unconfirmed(program, copied)); log(`connect fail code=unconfirmed program=${program} typed=${t} copied=${copied ? 1 : 0}`); return { ok: false, error: "unconfirmed" };
        }
        case "noWindow": {   // ни одного окна TeamViewer за срок — клиент не открылся (служба не в счёт): пароль не вводился
          const copied = copyID(record.id);
          hud.show(MESSAGES.noTeamViewerWindow(program, copied)); log(`connect fail code=noWindow program=${program} copied=${copied ? 1 : 0}`); return { ok: false, error: "noWindow" };
        }
        case "idMismatch": hud.show(MESSAGES.idMismatch(program)); log(`connect fail code=idMismatch`); return { ok: false, error: "idMismatch" };
        case "wrongPassword": hud.show(MESSAGES.wrongPassword()); log(`connect fail code=wrongPassword`); return { ok: false, error: "wrongPassword" };
        case "focusLost": hud.show(MESSAGES.focusLost()); log(`connect fail code=focusLost`); return { ok: false, error: "focusLost" };
        case "elevated": hud.show(MESSAGES.elevated(program)); log(`connect fail code=elevated`); return { ok: false, error: "elevated" };
        case "cancelled": hud.show({ kind: "info", title: "Отменено", autoHideMs: 1500 }); return { ok: false, error: "cancelled" };
        default: hud.show(MESSAGES.fieldNotFound(program)); log(`connect fail code=fieldNotFound`); return { ok: false, error: "fieldNotFound" };
      }
    } finally {
      for (const s of secrets) s?.wipe?.();      // затирание в любом исходе: ошибка, отмена, таймаут
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
