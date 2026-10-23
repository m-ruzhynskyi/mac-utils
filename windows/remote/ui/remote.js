// Окно «Удалённые подключения» и палитра (Win+Shift+A по умолчанию). Данные приходят готовыми из основного процесса; всё, что из файла
// (названия, группы, заметки), вставляется только как textContent.
"use strict";

const $ = (id) => document.getElementById(id);
const palette = location.hash === "#palette";
document.body.classList.toggle("palette", palette);

const SVG = {
  monitor: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>',
  key: '<circle cx="8" cy="15" r="4"/><path d="m11 12 8-8M16 7l3 3"/>',
  nokey: '<circle cx="8" cy="15" r="4"/><path d="m11 12 8-8M16 7l3 3M4 4l16 16"/>',
  star: '<path d="m12 3 2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1L3.2 9.500l6.1-.9z"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
};
function icon(name) {
  const ns = "http://www.w3.org/2000/svg", svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 24 24"); svg.setAttribute("aria-hidden", "true");
  svg.innerHTML = SVG[name];   // внутренняя разметка — только константы выше
  return svg;
}
function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

let view = null, filter = "all", selected = 0, rows = [], diagOpen = false, mode = "list";

// Текст с подсветкой совпадений: marks = [{start,end}].
function marked(parent, text, marks) {
  let at = 0;
  for (const m of marks || []) {
    if (m.start > at) parent.append(text.slice(at, m.start));
    const mark = document.createElement("mark"); mark.textContent = text.slice(m.start, m.end); parent.append(mark);
    at = m.end;
  }
  if (at < text.length) parent.append(text.slice(at));
}

async function refresh() {
  view = await window.rc.view($("query").value, filter);
  render();
}

const SKIP_REASONS = { missingName: "нет названия", missingID: "нет ID", invalidID: "ID не похож на ID", unknownProgram: "неизвестная программа", aliasNotSupported: "алиас не поддерживается этой программой" };
const FIELD_TITLES = { name: "Название", id: "ID", password: "Пароль", group: "Группа", tags: "Теги", note: "Заметка", program: "Программа" };

function emptyState(v) {
  const box = el("div", "empty");
  const [title, body] = {
    noFile: ["Файл подключений не выбран", "Выберите .xlsx или .xml со списком компьютеров или создайте шаблон."],
    unavailable: ["Файл подключений недоступен", "Проверьте путь, диск или сетевую папку. Список появится, как только файл станет доступен."],
    locked: ["Файл занят другой программой", "Закройте файл или нажмите «Перечитать» чуть позже."],
    type: ["Не тот формат файла", "Поддерживаются .xlsx и .xml."],
    tooLarge: ["Файл слишком большой", "Список не должен быть больше 64 МБ."],
    noSheet: ["Нет такого листа", "Выберите лист в настройках."],
    missingColumns: ["Не найдены колонки «Название» и «ID»", "Нашлись заголовки: " + ((v.error && v.error.found.length) ? v.error.found.join(", ") : "—")],
    corrupt: ["Файл повреждён", (v.error && v.error.detail) || "Не удалось прочитать файл. Прежний список не сохранён."],
  }[v.error ? v.error.code : "noFile"] || ["Нет данных", ""];
  box.append(el("h2", null, title), el("div", null, body));
  const actions = el("div"); actions.style.cssText = "margin-top:14px;display:flex;gap:8px;justify-content:center";
  const choose = el("button", "btn pri", "Выбрать файл"); choose.onclick = async () => { await window.rc.chooseFile(); refresh(); };
  actions.append(choose);
  if (!v.error || v.error.code === "noFile") { const t = el("button", "btn", "Создать шаблон"); t.onclick = () => { openSettings(); }; actions.append(t); }
  box.append(actions);
  return box;
}

function render() {
  const v = view;
  $("hotkeyHint").textContent = v.hotkey;
  // Чипы с количеством
  const chips = $("chips"); chips.textContent = "";
  for (const [id, title] of [["all", "Все"], ["anyDesk", "AnyDesk"], ["teamViewer", "TeamViewer"]]) {
    const b = el("button", "chip" + (filter === id ? " sel" : ""), `${title} ${v.counts[id] ?? 0}`);
    b.onclick = () => { filter = id; selected = 0; refresh(); $("query").focus(); };
    chips.append(b);
  }
  const hint = $("layoutHint");
  hint.hidden = !v.hint;
  if (v.hint) { hint.textContent = ""; hint.append(`${v.hint.typed} → `, Object.assign(el("b"), { textContent: v.hint.converted })); }
  // Баннер: программы нет на компьютере
  const banner = $("banner"); banner.textContent = "";
  for (const p of ["anyDesk", "teamViewer"]) {
    if (!v.installed[p] && (v.counts[p] || 0) > 0) {
      const b = el("div", "banner warning"); b.append(el("div", null, `${v.titles[p]} не установлен. Записи этой программы приглушены.`));
      const get = el("button", "btn c", "Скачать"); get.onclick = () => window.rc.edit("download", p); b.append(get); banner.append(b);
    }
  }
  const list = $("list"); list.textContent = "";
  rows = [];
  if (v.status !== "ready") { list.append(emptyState(v)); }
  else if (!v.sections.some((s) => s.records.length)) {
    const box = el("div", "empty"); box.append(el("h2", null, v.query ? "Ничего не найдено" : "Список пуст"), el("div", null, v.query ? "Попробуйте другое слово или ID." : "В файле нет ни одной корректной записи."));
    list.append(box);
  } else {
    for (const s of v.sections) {
      if (!s.records.length) continue;
      const head = el("div", "sec");
      head.append(icon(s.kind === "favorites" ? "star" : s.kind === "recents" ? "clock" : s.kind === "results" ? "search" : "folder"));
      head.append(document.createTextNode({ favorites: "Избранное", recents: "Недавние", results: "Найдено", ungrouped: "Без группы" }[s.kind] || s.title), el("span", null, String(s.records.length)));
      const card = el("div", "card");
      list.append(head, card);
      for (const r of s.records) {
        const index = rows.length; rows.push(r);
        card.append(rowElement(r, index, s.kind));
      }
    }
    selected = Math.min(selected, rows.length - 1);
    highlight();
  }
  renderSummary();
  $("addBtn").hidden = !(v.status === "ready" && v.canEdit);
}

function rowElement(r, index, kind) {
  const row = el("div", "row" + (r.dim ? " dim" : "")); row.dataset.index = index; row.setAttribute("role", "option");
  const tile = el("div", "tile"); tile.append(icon("monitor"));
  const text = el("div", "t"); const name = el("b"); marked(name, r.name, r.nameMarks);
  const small = el("small"); const id = el("span", "mono"); marked(id, r.id, r.idMarks); small.append(id);
  // Группа видна в заголовке секции; в «Избранном», «Недавних» и результатах поиска — рядом с ID.
  if (r.group && ["favorites", "recents", "results"].includes(kind)) small.append(` · ${r.group}`);
  text.append(name, small);
  const prov = el("span", "prov " + (r.program === "anyDesk" ? "ad" : "tv") + (r.dim ? " dim" : "")); prov.append(el("i"), document.createTextNode(r.program === "anyDesk" ? "AD" : "TV")); prov.title = r.programTitle;
  const pw = el("span", "pw" + (r.hasPassword ? " on" : "")); pw.append(icon(r.hasPassword ? "key" : "nokey")); pw.title = r.hasPassword ? "Есть пароль" : "Пароля нет";
  const star = el("button", "star" + (r.favorite ? " on" : "")); star.append(icon("star")); star.title = r.favorite ? "Убрать из избранного" : "В избранное"; star.setAttribute("aria-label", star.title);
  star.style.cssText = "border:0;background:transparent"; star.onclick = async (e) => { e.stopPropagation(); await window.rc.toggleFavorite(r.key); };
  row.append(tile, text, prov, pw, star);
  if (view.canEdit) { const edit = el("button", "star", "✎"); edit.title = "Изменить запись"; edit.setAttribute("aria-label", "Изменить запись"); edit.style.cssText = "border:0;background:transparent"; edit.onclick = (e) => { e.stopPropagation(); openEditor(r); }; row.append(edit); }
  row.onclick = () => { selected = index; highlight(); };
  row.ondblclick = () => connect(r, false);
  return row;
}

function highlight() {
  document.querySelectorAll(".row").forEach((r) => r.classList.toggle("sel", Number(r.dataset.index) === selected));
  document.querySelector(".row.sel")?.scrollIntoView({ block: "nearest" });
}

function renderSummary() {
  const v = view, s = $("summary"), box = $("diagBox");
  box.textContent = "";
  if (v.status !== "ready" || !v.diagnostics) { s.textContent = ""; return; }
  const d = v.diagnostics;
  s.textContent = d.clean ? `Загружено ${d.loaded}` : `Загружено ${d.loaded} · пропущено ${d.skippedCount} · дубликатов ${d.duplicateCount} ${diagOpen ? "⌄" : "›"}`;
  s.onclick = s.onkeydown = (e) => { if (e.type === "keydown" && e.key !== "Enter") return; if (d.clean) return; diagOpen = !diagOpen; renderSummary(); };
  if (!diagOpen || d.clean) return;
  const panel = el("div", "diag");
  const section = (title, items) => { if (!items.length) return; panel.append(el("h4", null, title)); const ul = el("ul"); for (const t of items) ul.append(el("li", null, t)); panel.append(ul); };
  section("Колонки", d.columns.map((c) => `${c.letter ? c.letter + " · " : ""}${c.title} → ${FIELD_TITLES[c.field]}`));
  section("Пропущенные строки", d.skipped.map((x) => `строка ${x.row}: ${SKIP_REASONS[x.reason]}${x.value ? ` («${x.value}»)` : ""}`));
  section("Дубликаты по ID", d.duplicates.map((g) => `строки ${g.rows.join(", ")}: ${g.names.join(" / ")}`));
  section("Не распознаны колонки", d.unrecognizedColumns);
  section("ID записан как 1.23E+08 — цифры могли потеряться", d.lossyIDRows.map((n) => `строка ${n}`));
  section("Программа не указана, а в файле есть обе — взята программа по умолчанию", d.ambiguousProgramRows.map((n) => `строка ${n}`));
  box.append(panel);
}

async function connect(record, noPassword) {
  if (!record) return;
  if (palette) window.rc.closePalette();
  await window.rc.connect(record.key, noPassword);
}

function move(delta) {
  if (!rows.length) return;
  selected = (selected + delta + rows.length) % rows.length;
  highlight();
}

$("query").addEventListener("input", () => { selected = 0; refresh(); });
document.addEventListener("keydown", (e) => {
  if (mode === "settings" || mode === "edit") return;
  if (e.key === "ArrowDown") { e.preventDefault(); move(1); }
  else if (e.key === "ArrowUp") { e.preventDefault(); move(-1); }
  else if (e.key === "Enter") { e.preventDefault(); connect(rows[selected], e.ctrlKey || e.metaKey); }
  else if (e.key === "Tab") {
    e.preventDefault();
    const order = ["all", "anyDesk", "teamViewer"];
    filter = order[(order.indexOf(filter) + (e.shiftKey ? 2 : 1)) % 3]; selected = 0; refresh();
  }
  else if ((e.key === "f" || e.key === "F") && e.ctrlKey) { e.preventDefault(); if (rows[selected]) window.rc.toggleFavorite(rows[selected].key); }
  else if (e.key === "Escape") { if (palette) window.rc.closePalette(); else if ($("query").value) { $("query").value = ""; refresh(); } }
});
$("addBtn").hidden = true;
$("addBtn").onclick = () => openEditor(null);
$("openFile").onclick = () => window.rc.openFile();
$("reload").onclick = () => window.rc.reload();
$("settingsBtn").onclick = () => openSettings();

// ---- правка записи (только .xml): лист поверх списка ----
const EDIT_ERRORS = { missingName: "Укажите название.", missingID: "Укажите ID.", invalidID: "ID должен быть из 9–10 цифр или вида имя@ad.", unknownProgram: "Неизвестная программа.",
  aliasNotSupported: "Алиас вида имя@ad работает только с AnyDesk.", gone: "Записи больше нет в файле — список обновлён.", writeFailed: "Не удалось сохранить файл. Копия .bak рядом.", corrupt: "Файл не читается как XML.", xlsxReadOnly: "Файлы .xlsx не правятся — только .xml." };
function openEditor(record) {
  mode = "edit";
  $("page").hidden = true;
  let box = $("editBox"); if (box) box.remove();
  box = el("div", "settings"); box.id = "editBox"; document.body.append(box);
  const inputs = {};
  const field = (key, label, value) => { const l = el("label", null, label); const i = el("input"); i.type = "text"; i.value = value || ""; inputs[key] = i; l.append(i); return l; };
  const program = el("select"); program.append(new Option("По умолчанию", ""), new Option("AnyDesk", "AnyDesk"), new Option("TeamViewer", "TeamViewer"));
  program.value = record ? ({ anyDesk: "AnyDesk", teamViewer: "TeamViewer" }[record.programFile] || "") : "";
  const error = el("div", "banner danger"); error.hidden = true;
  const close = () => { box.remove(); $("page").hidden = false; mode = "list"; refresh(); };
  const save = el("button", "btn pri", record ? "Сохранить" : "Добавить");
  save.onclick = async () => {
    const fields = { name: inputs.name.value, id: inputs.id.value, group: inputs.group.value, tags: inputs.tags.value, note: inputs.note.value, program: program.value };
    const r = await window.rc.edit(record ? "update" : "add", { key: record && record.key, fields });
    if (r.ok) return close();
    error.textContent = EDIT_ERRORS[r.error] || "Не удалось сохранить."; error.hidden = false;
  };
  const cancel = el("button", "btn", "Отмена"); cancel.onclick = close;
  const actions = el("div"); actions.style.cssText = "display:flex;gap:8px"; actions.append(save, cancel);
  if (record) {
    const del = el("button", "btn dng", "Удалить"); let armed = false;
    del.onclick = async () => { if (!armed) { armed = true; del.textContent = "Точно удалить?"; return; } const r = await window.rc.edit("remove", { key: record.key }); if (r.ok) close(); else { error.textContent = EDIT_ERRORS[r.error] || "Не удалось удалить."; error.hidden = false; } };
    actions.append(del);
  }
  box.append(el("h2", null, record ? "Изменить запись" : "Добавить запись"), error, field("name", "Название", record && record.name), field("id", "ID или алиас (имя@ad)", record && record.rawID),
    field("group", "Группа", record && record.group), field("tags", "Теги (через запятую)", record && record.tags), field("note", "Заметка", record && record.note), (() => { const l = el("label", null, "Программа"); l.append(program); return l; })(),
    el("div", "muted", "Пароль здесь не показывается и не меняется. Перед сохранением рядом создаётся копия .bak."), actions);
}

// ---- настройки (раздел внутри окна) ----
async function openSettings() {
  mode = "settings";
  const page = $("page"); page.hidden = true;
  let box = $("settingsBox"); if (box) box.remove();
  box = el("div", "settings"); box.id = "settingsBox";
  document.body.append(box);
  const s = await window.rc.getSettings();
  const field = (label, input) => { const l = el("label", null, label); l.append(input); return l; };
  const text = (value, onChange, type = "text") => { const i = el("input"); i.type = type; i.value = value; i.onchange = () => onChange(i.value); return i; };
  const warn = el("div", "banner warning"); warn.append(el("div", null, "Пароли лежат в файле открытым текстом. Включите шифрование диска, ограничьте доступ к файлу и папке, не пересылайте его. Mac Utils пароли нигде не хранит. При правке XML рядом остаётся копия .bak с теми же паролями (права Windows на неё не переносятся, облако её синхронизирует) — удаляйте её, когда она не нужна."));
  const row = el("div"); row.style.cssText = "display:flex;gap:8px";
  const path = text(s.file, async (v) => { await window.rc.setSettings({ file: v }); });
  path.style.flex = "1";
  const pick = el("button", "btn c", "Выбрать…"); pick.onclick = async () => { const f = await window.rc.chooseFile(); if (f) path.value = f; };
  row.append(path, pick);
  const sheetSel = el("select"); sheetSel.onchange = () => window.rc.setSettings({ sheet: sheetSel.value });
  const loadSheets = async () => { const names = await window.rc.sheets(); sheetSel.textContent = ""; sheetSel.append(new Option("Первый лист", "")); for (const n of names) sheetSel.append(new Option(n, n, false, n === s.sheet)); sheetSel.disabled = !names.length; };
  const program = el("select"); program.append(new Option("AnyDesk", "anyDesk"), new Option("TeamViewer", "teamViewer")); program.value = s.defaultProgram; program.onchange = () => window.rc.setSettings({ defaultProgram: program.value });
  const hot = text(s.hotkey, async (v) => {
    const r = await window.rc.setSettings({ hotkey: v });
    note.textContent = r.hotkeyOk === false ? "Сочетание занято или не подходит: нужен Ctrl, Alt или Win и клавиша (например, Win+Shift+A)."
      : r.hotkeyProblem === "altgr" ? "Осторожно: Ctrl+Alt — это AltGr на польской, венгерской и других раскладках, сочетание перехватит ввод букв. Лучше Win+Shift+буква."
      : HOTKEY_NOTE;
  });
  const HOTKEY_NOTE = "По умолчанию Win+Shift+A. Клавиша и значок в трее включаются после выбора файла. Не используйте Ctrl+Alt+буква: на раскладках с AltGr оно перехватит ввод.";
  const note = el("div", "muted"); note.textContent = HOTKEY_NOTE;
  const timeout = text(String(s.timeoutSeconds), (v) => window.rc.setSettings({ timeoutSeconds: Number(v) }), "number");
  const check = (label, key, value) => { const l = el("label", "inline"); const c = el("input"); c.type = "checkbox"; c.checked = value; c.onchange = () => window.rc.setSettings({ [key]: c.checked }); l.append(c, document.createTextNode(label)); return l; };
  const paths = ["anyDesk", "teamViewer"].map((p) => field(`Путь к ${p === "anyDesk" ? "AnyDesk" : "TeamViewer"} (если не найден сам)`, text(s.programPaths[p], (v) => window.rc.setSettings({ programPaths: { [p]: v } }))));
  const tpl = el("div"); tpl.style.cssText = "display:flex;gap:8px";
  for (const kind of ["xlsx", "xml"]) { const b = el("button", "btn c", `Создать шаблон .${kind}`); b.onclick = async () => { const f = await window.rc.createTemplate(kind); if (f) path.value = f; }; tpl.append(b); }
  const back = el("button", "btn pri", "Готово"); back.onclick = () => { box.remove(); page.hidden = false; mode = "list"; refresh(); $("query").focus(); };
  box.append(el("h2", null, "Удалённые подключения · настройки"), warn, field("Файл подключений (.xlsx или .xml)", row), tpl, field("Лист", sheetSel), field("Программа по умолчанию", program),
    field("Горячая клавиша", hot), note, field("Ожидание окна пароля, с", timeout), check("Входить автоматически (AnyDesk)", "autoLogin", s.autoLogin),
    check("Уведомление после подключения", "notify", s.notify), ...paths, back);
  loadSheets();
}

window.rc.onChanged(refresh);
window.rc.onShow(() => { if (mode === "settings" || mode === "edit") return; $("query").value = ""; filter = "all"; selected = 0; refresh(); $("query").focus(); });
if (palette) { $("hints").hidden = false; $("bar").hidden = true; }
refresh().then(() => $("query").focus());
