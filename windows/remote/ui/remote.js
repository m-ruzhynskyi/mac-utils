// Окно «Удалённые подключения» и палитра (Win+Shift+A по умолчанию). Данные приходят готовыми из основного процесса; всё, что из файла
// (названия, группы, заметки, метки, логины, «Доступ»), вставляется только как textContent. Вид строки и подробностей — по макету
// .audit/rc-tags-design (Main / Details), как на Mac.
"use strict";

const $ = (id) => document.getElementById(id);
const palette = location.hash === "#palette";
document.body.classList.toggle("palette", palette);

const SVG = {
  monitor: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>',
  key: '<circle cx="8" cy="15" r="4"/><path d="M11 12l9-9M17 6l3 3"/>',
  nokey: '<circle cx="8" cy="15" r="4"/><path d="m11 12 8-8M16 7l3 3M4 4l16 16"/>',
  star: '<path d="m12 3 2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1L3.2 9.500l6.1-.9z"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
  shield: '<path d="M12 3l7 3v5c0 4.5-3 8-7 10-4-2-7-5.5-7-10V6z"/>',
  person: '<circle cx="12" cy="8" r="4"/><path d="M4 21c1.5-4 4.5-6 8-6s6.5 2 8 6"/>',
  note: '<path d="M5 4h14v12l-4 4H5z"/><path d="M15 20v-4h4"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5v.5"/>',
  back: '<path d="M15 5l-7 7 7 7"/>',
  eye: '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
  eyeOff: '<path d="M2 12s3.5-7 10-7c2 0 3.8.7 5.2 1.6M22 12s-3.5 7-10 7c-2 0-3.8-.7-5.2-1.6M4 4l16 16"/>',
  phone: '<path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2z"/>',
};
function icon(name, cls) {
  const ns = "http://www.w3.org/2000/svg", svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 24 24"); svg.setAttribute("aria-hidden", "true");
  if (cls) svg.setAttribute("class", cls);
  svg.innerHTML = SVG[name];   // внутренняя разметка — только константы выше
  return svg;
}
function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
function button(cls, text, onClick, label) {
  const b = el("button", cls, text); b.type = "button";
  if (label) { b.title = label; b.setAttribute("aria-label", label); }
  if (onClick) b.onclick = onClick;
  return b;
}

// mode: list | details | edit | settings. selectedTags — ключи выбранных меток (все сразу); detailsKey — запись в подробностях.
let view = null, filter = "all", selected = 0, rows = [], diagOpen = false, mode = "list";
let selectedTags = new Set(), tagsExpanded = false, detailsKey = null;

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

// «1 строка скрыта», «3 строки скрыты», «6 строк скрыто».
function hiddenLines(n) {
  const d = n % 10, h = n % 100;
  if (d === 1 && h !== 11) return `${n} строка скрыта`;
  if (d >= 2 && d <= 4 && (h < 12 || h > 14)) return `${n} строки скрыты`;
  return `${n} строк скрыто`;
}

async function refresh() {
  view = await window.rc.view($("query").value, filter, [...selectedTags]);
  if (mode === "details") return renderDetails();
  if (mode === "list") render();
}

const SKIP_REASONS = { missingName: "нет названия", missingID: "нет ID", invalidID: "ID не похож на ID", unknownProgram: "неизвестная программа", aliasNotSupported: "алиас не поддерживается этой программой" };
const FIELD_TITLES = { name: "Название", id: "ID", password: "Пароль", group: "Группа", tags: "Теги", note: "Заметка", program: "Программа",
  account: "Учётная запись", accountPassword: "Пароль учётной записи", access: "Доступ", contacts: "Контакты" };
const PROGRAM_FILTERS = [["all", "Все"], ["anyDesk", "AnyDesk"], ["teamViewer", "TeamViewer"], ["rdp", "RDP"], ["vpn", "VPN"]];

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
  if (!v.error || v.error.code === "noFile") {
    for (const kind of ["xlsx", "xml"]) { const t = el("button", "btn", `Создать шаблон .${kind}`); t.onclick = async () => { await window.rc.createTemplate(kind); refresh(); }; actions.append(t); }
  }
  box.append(actions);
  return box;
}

// Фильтры программы: «Все / AnyDesk / TeamViewer», RDP и VPN — только если такие записи есть (или фильтр уже выбран).
function visibleFilters(v) {
  return PROGRAM_FILTERS.filter(([id]) => !(id === "rdp" || id === "vpn") || (v.counts[id] || 0) > 0 || filter === id);
}

function setFilter(id) { filter = id; selected = 0; refresh(); $("query").focus(); }

function renderChips(v) {
  const chips = $("chips"); chips.textContent = "";
  if (v.status !== "ready") return;
  for (const [id, title] of visibleFilters(v)) {
    const b = el("button", "chip" + (filter === id ? " sel" : "")); b.type = "button";
    if (id === "rdp" || id === "vpn") b.append(icon(id === "rdp" ? "monitor" : "shield", "ci " + id));
    b.append(`${title} ${v.counts[id] ?? 0}`);
    b.setAttribute("aria-pressed", String(filter === id));
    b.onclick = () => setFilter(id);
    chips.append(b);
  }
}

// Метка: «Рег» — синяя, «Фито» — зелёная, остальные — серые; с точкой.
// large — размер строки «МЕТКИ» и подробностей; filterChip — кнопка фильтра (выбранная — с обводкой).
function labelChip(title, kind, { large = false, count = null, selectedChip = false, filterChip = false } = {}) {
  const chip = el(filterChip ? "button" : "span", `lab ${kind}` + (large ? " lg" : "") + (selectedChip ? " on" : ""));
  chip.append(el("i"), count == null ? title : `${title} ${count}`);
  if (filterChip) { chip.type = "button"; chip.setAttribute("aria-pressed", String(selectedChip)); }
  return chip;
}
// Значок «VPN» (оранжевый щит) или «RDP» (фиолетовый монитор).
function badge(kind, large = false) {
  const b = el(large ? "span" : "button", `bdg ${kind}` + (large ? " lg" : ""));
  b.append(icon(kind === "vpn" ? "shield" : "monitor"), kind === "vpn" ? "VPN" : "RDP");
  b.title = kind === "vpn" ? "Сначала подключите VPN" : "Подключение через удалённый рабочий стол";
  if (!large) b.type = "button";
  return b;
}

// Строка «МЕТКИ»: Рег, Фито, остальные по частоте; видны 4 (и выбранные), остальные — «ещё N». Можно выбрать несколько.
function renderTagRow(v) {
  const box = $("tagRow"); box.textContent = "";
  const tags = v.status === "ready" ? v.tags || [] : [];
  box.hidden = !tags.length;
  if (!tags.length) return;
  box.append(el("span", "cap", "МЕТКИ"));
  const shown = tagsExpanded ? tags : [...tags.slice(0, 4), ...tags.slice(4).filter((t) => selectedTags.has(t.key))];
  for (const t of shown) {
    const chip = labelChip(t.title, t.kind, { large: true, count: t.count, selectedChip: selectedTags.has(t.key), filterChip: true });
    chip.onclick = () => { if (selectedTags.has(t.key)) selectedTags.delete(t.key); else selectedTags.add(t.key); selected = 0; refresh(); };
    box.append(chip);
  }
  const hidden = tags.length - shown.length;
  if (hidden > 0) { const more = button("lab more lg", `ещё ${hidden}`, () => { tagsExpanded = true; renderTagRow(view); }); box.append(more); }
}

function render() {
  const v = view;
  $("hotkeyHint").textContent = v.hotkey;
  renderChips(v);
  renderTagRow(v);
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
    const box = el("div", "empty"); box.append(el("h2", null, v.query || selectedTags.size ? "Ничего не найдено" : "Список пуст"),
      el("div", null, v.query || selectedTags.size ? "Поиск идёт по названию, ID, группе, меткам, заметке и логину. Попробуйте другое слово или снимите метку." : "В файле нет ни одной корректной записи."));
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
    fitAllLabels();
  }
  renderSummary();
  $("addBtn").hidden = palette || !(v.status === "ready" && v.canEdit);
}

const KIND = { anyDesk: ["ad", "AD"], teamViewer: ["tv", "TV"], rdp: ["rdp", "RDP"], vpn: ["vpn", "VPN"], other: ["oth", "Другое"] };

// Строка (макет Main): название и значки VPN/RDP; ID (никогда не переносится) и логин учётки; метки одной строкой; заметка;
// справа — программа, «i» (подробности) и ключ.
function rowElement(r, index, kind) {
  const row = el("div", "row" + (r.dim ? " dim" : "")); row.dataset.index = index; row.setAttribute("role", "option");
  const tile = el("div", "tile"); tile.append(icon("monitor"));
  const text = el("div", "t");
  const l1 = el("div", "l1"); const name = el("span", "nm"); marked(name, r.name, r.nameMarks); l1.append(name);
  for (const b of [r.needsVPN && "vpn", r.usesRDP && "rdp"].filter(Boolean)) {
    const chip = badge(b); chip.onclick = (e) => { e.stopPropagation(); openDetails(r.key); }; l1.append(chip);
  }
  const l2 = el("div", "l2");
  const id = el("span", "rid" + (r.id ? "" : " none"));
  if (r.id) marked(id, r.id, r.idMarks); else id.textContent = "без ID";
  l2.append(id);
  if (r.account) {
    const login = el("span", "login"); login.title = "Учётка Windows"; login.append(icon("person"));
    const t = el("span", "tx"); marked(t, r.account, r.accountMarks); login.append(t); l2.append(login);
  } else if (r.group && ["favorites", "recents", "results"].includes(kind)) {
    // Группа видна в заголовке секции; в «Избранном», «Недавних» и результатах — рядом с ID (ужимается она, а не ID).
    l2.append(el("span", "grp", `· ${r.group}`));
  }
  text.append(l1, l2);
  if (r.labels.length) { const labels = el("div", "labels"); labels.labels = r.labels; text.append(labels); }
  if (r.noteLine) {
    const note = el("div", "note"); note.title = r.note; note.append(icon("note"));
    const t = el("span", "tx"); marked(t, r.noteLine, r.noteMarks); note.append(t); text.append(note);
  }
  const side = el("div", "side");
  const [cls, short] = KIND[r.method || r.program] || KIND.anyDesk;
  const prov = el("span", `prov ${cls}` + (r.dim ? " dim" : "")); prov.append(el("i"), document.createTextNode(short)); prov.title = r.dim ? `${r.programTitle} не установлен` : r.programTitle;
  const btns = el("div", "btns");
  const info = button("ib", null, (e) => { e.stopPropagation(); openDetails(r.key); }, "Подробности"); info.append(icon("info"));
  const pw = el("span", "ib pw" + (r.hasPassword ? " on" : "")); pw.append(icon(r.hasPassword ? "key" : "nokey"));
  pw.title = r.hasPassword ? "Пароль есть в файле" : "В файле нет пароля — введите вручную"; pw.setAttribute("aria-label", r.hasPassword ? "Пароль есть" : "Пароля нет");
  btns.append(info, pw);
  side.append(prov, btns);
  row.append(tile, text, side);
  row.onclick = () => { selected = index; highlight(); };
  row.ondblclick = () => activate(r, false);
  row.oncontextmenu = (e) => { e.preventDefault(); selected = index; highlight(); window.rc.rowMenu(r.key); };
  return row;
}

// Метки одной строкой: сколько влезло (не больше 6) + «+N», в подсказке — остальные. Сначала все чипы в строке, затем одно
// измерение ширин на весь список и одна запись — без перекладки на каждую строку.
function fitAllLabels() {
  const boxes = [...document.querySelectorAll(".row .labels")];
  for (const box of boxes) {
    box.textContent = "";
    for (const l of box.labels.slice(0, 6)) box.append(labelChip(l.title, l.kind));
    box.append(el("span", "lab more", `+${box.labels.length}`));
  }
  const measured = boxes.map((box) => ({ box, width: box.clientWidth, chips: [...box.children].map((c) => c.offsetWidth) }));
  for (const { box, width, chips } of measured) {
    const labels = box.labels, more = chips.pop(), gap = 5;
    let k = Math.min(labels.length, 6);
    const fits = (n) => chips.slice(0, n).reduce((sum, w) => sum + w, 0) + Math.max(0, n - 1) * gap + (n < labels.length ? (n ? gap : 0) + more : 0) <= width;
    while (k > 0 && !fits(k)) k--;
    while (box.children.length > k) box.lastChild.remove();
    if (k < labels.length) {
      const rest = el("span", "lab more", `+${labels.length - k}`);
      rest.title = labels.slice(k).map((l) => l.title).join(", ");
      box.append(rest);
    }
  }
}
let resizeTimer = null;
window.addEventListener("resize", () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(() => { if (mode === "list") fitAllLabels(); }, 80); });

function highlight() {
  document.querySelectorAll(".row").forEach((r) => r.classList.toggle("sel", Number(r.dataset.index) === selected));
  document.querySelector(".row.sel")?.scrollIntoView({ block: "nearest" });
}

// Строка «Загружено N · пропущено …» с диагностикой — только в окне списка; в палитре внизу лишь «Обновить».
function renderSummary() {
  const v = view, s = $("summary"), box = $("diagBox");
  box.textContent = "";
  if (palette) { s.textContent = ""; return; }
  if (v.status !== "ready" || !v.diagnostics) { s.textContent = ""; return; }
  const d = v.diagnostics;
  const extra = (d.vpn ? ` · VPN ${d.vpn}` : "") + (d.rdp ? ` · RDP ${d.rdp}` : "");
  s.textContent = d.clean ? `Загружено ${d.loaded}${extra}` : `Загружено ${d.loaded} · пропущено ${d.skippedCount} · дубликатов ${d.duplicateCount} ${diagOpen ? "⌄" : "›"}`;
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

// Enter / двойной щелчок: AnyDesk/TeamViewer — подключиться; RDP с адресом — mstsc; VPN, «Другое», RDP без адреса — подробности.
async function activate(record, noPassword) {
  if (!record) return;
  if (record.method && !record.rdpHost) return openDetails(record.key);
  if (palette) window.rc.closePalette();
  const result = await window.rc.connect(record.key, noPassword);
  if (result && result.error === "details") openDetails(record.key);
}

function move(delta) {
  if (!rows.length) return;
  selected = (selected + delta + rows.length) % rows.length;
  highlight();
}

$("query").addEventListener("input", () => { selected = 0; refresh(); });
document.addEventListener("keydown", (e) => {
  if (mode === "settings" || mode === "edit") return;
  if (mode === "details") {
    if (e.key === "Escape") { e.preventDefault(); closeDetails(); }
    else if (e.key === "Enter" && !e.target.closest?.("button")) {
      const r = currentDetails, rdp = currentCard && currentCard.howto && currentCard.howto.rdp;
      if (r && rdp && rdp.canOpen) { e.preventDefault(); openRDPFromDetails(r, rdp.fromAccess); }
    }
    return;
  }
  if (e.key === "ArrowDown") { e.preventDefault(); move(1); }
  else if (e.key === "ArrowUp") { e.preventDefault(); move(-1); }
  else if (e.key === "Enter") { e.preventDefault(); activate(rows[selected], e.ctrlKey || e.metaKey); }
  else if (e.key === "Tab") {
    e.preventDefault();
    const order = visibleFilters(view).map(([id]) => id);
    filter = order[(order.indexOf(filter) + (e.shiftKey ? order.length - 1 : 1)) % order.length]; selected = 0; refresh();
  }
  else if ((e.key === "f" || e.key === "F") && e.ctrlKey) { e.preventDefault(); if (rows[selected]) window.rc.toggleFavorite(rows[selected].key); }
  else if ((e.key === "i" || e.key === "I") && e.ctrlKey) { e.preventDefault(); if (rows[selected]) openDetails(rows[selected].key); }
  else if (e.key === "Escape") { if (palette) window.rc.closePalette(); else if ($("query").value) { $("query").value = ""; refresh(); } }
});
$("addBtn").hidden = true;
$("addBtn").onclick = () => openEditor(null);
$("openFile").onclick = () => window.rc.openFile();
$("folderBtn").append(icon("folder"));
$("folderBtn").onclick = () => window.rc.showFolder();
$("reload").onclick = () => window.rc.reload();
$("settingsBtn").onclick = () => openSettings();

// ---- подробности записи (макет Details): экран вместо списка ----
// Пароль учётки и пароль/ключ VPN на экран не выводятся никогда (в окно они и не приходят); «Доступ» — только по «Показать»;
// «Как подключиться» и «Контакты» — из файла при открытии экрана. Всё это живёт, только пока открыт этот экран: при уходе с
// экрана (и при перечитывании файла) текст из окна убирается.
let currentDetails = null, currentCard = null;

async function openDetails(key) {
  detailsKey = key;
  mode = "details";
  $("page").hidden = true;
  await renderDetails();
}

function closeDetails() {
  detailsKey = null; currentDetails = null; currentCard = null;
  $("detailsBox")?.remove();   // вместе с ним — показанный «Доступ»
  $("page").hidden = false;
  mode = "list";
  refresh().then(() => $("query").focus());
}

function openRDPFromDetails(r, fromAccess = false) {
  if (palette) window.rc.closePalette();
  window.rc.openRDP(r.key, fromAccess);
}

async function renderDetails() {
  const key = detailsKey;
  const [r, card] = key ? await Promise.all([window.rc.details(key), window.rc.cardInfo(key)]) : [null, null];
  if (mode !== "details" || key !== detailsKey) return;
  if (!r) return closeDetails();   // записи больше нет в файле
  currentDetails = r; currentCard = card && card.ok ? card : null;
  const howto = currentCard ? currentCard.howto : { vpn: null, rdp: null };
  $("detailsBox")?.remove();
  const box = el("div", "details"); box.id = "detailsBox"; box.setAttribute("role", "region"); box.setAttribute("aria-label", `Подробности: ${r.name}`);
  document.body.append(box);

  const head = el("div", "dhead");
  const back = button("btn round", null, closeDetails, "Назад к списку"); back.append(icon("back"));
  const titles = el("div", "dtitles");
  const parts = [];
  if (r.group) parts.push(`Группа «${r.group}»`);
  parts.push(r.methodTitle || r.programTitle);
  if (r.id) parts.push(r.id);
  titles.append(el("h2", null, r.name), el("span", null, parts.join(" · ")));
  head.append(back, titles);
  box.append(head);

  const scroll = el("div", "dscroll"); box.append(scroll);
  if (r.labels.length || r.needsVPN || r.usesRDP) {
    const tags = el("div", "dtags");
    for (const l of r.labels) tags.append(labelChip(l.title, l.kind, { large: true }));
    if (r.needsVPN) tags.append(badge("vpn", true));
    if (r.usesRDP) tags.append(badge("rdp", true));
    scroll.append(tags);
  }
  if (r.needsVPN) {
    const b = el("div", "vpnbanner"); b.append(icon("shield"));
    const t = el("div"); t.append(el("b", null, "Сначала подключите VPN"),
      el("span", null, r.accessLines > 0 ? "Компьютер виден только через VPN. Профиль и ключ — в разделе «Доступ» ниже." : "Компьютер виден только через VPN."));
    b.append(t); scroll.append(b);
  }
  if (r.needsVPN || r.usesRDP || howto.vpn || howto.rdp) scroll.append(howToCard(r, howto));
  if (r.account || r.hasAccountPassword) {
    const card = el("div", "dcard");
    card.append(el("div", "dlbl", "УЧЁТКА WINDOWS"));
    const line = el("div", "acct");
    line.append(el("b", null, r.account || "—"));
    if (r.hasAccountPassword) {
      const dots = el("span", "dots", "••••••••"); dots.setAttribute("aria-hidden", "true");
      line.append(dots, button("btn c", "Копировать пароль", () => window.rc.copySecret(r.key, "accountPassword"), "Скопировать пароль учётки"));
    }
    card.append(line);
    if (r.hasAccountPassword) card.append(el("small", "muted", "Буфер очистится через 30 с. Пароль на экране не показывается."));
    scroll.append(card);
  }
  if (currentCard && currentCard.contacts && currentCard.contacts.text) scroll.append(contactsCard(currentCard.contacts));
  if (r.note) {
    const card = el("div", "dcard"); card.append(el("div", "dlbl", "ЗАМЕТКА"), el("div", "dnote", r.note)); scroll.append(card);
  }
  if (r.accessLines > 0) scroll.append(accessCard(r));
}

// Строка «название — значение» в карточке.
function fact(title, value, mono = false) {
  const line = el("div", "fact"); line.append(el("span", "fk", title), el("b", mono ? "fv mono" : "fv", value)); return line;
}
// Строки «Доступа», которые разобрать не удалось, — как сам «Доступ»: до «Показать» только размытые полосы, после — строки
// (моноширинно, с переносами) с паролями и ключами под маской (её ставит основной процесс). Пароль без метки маска не найдёт —
// поэтому «Показать».
function rawLines(lines) {
  const box = el("div", "rawbox"), pane = el("div", "apane raw"), toggle = button("btn c sm");
  let shown = false;
  const render = () => {
    pane.textContent = ""; toggle.textContent = "";
    if (shown) {
      pane.append(el("pre", "rawlines", lines.join("\n")));
      toggle.append(icon("eyeOff"), "Скрыть");
    } else {
      const bars = el("div", "bars"); bars.setAttribute("aria-hidden", "true");
      const widths = [190, 240, 150, 120, 210, 230, 170, 140];
      for (let i = 0; i < Math.min(lines.length, 8); i++) { const b = el("i"); b.style.width = `${widths[i % 8]}px`; bars.append(b); }
      pane.append(bars, el("span", "veil", `${hiddenLines(lines.length)} · могут быть пароли`));
      toggle.append(icon("eye"), "Показать");
    }
  };
  toggle.onclick = () => { shown = !shown; render(); };
  render();
  box.append(pane, toggle);
  return box;
}

// «Как подключиться»: VPN (тип, сервер, логин, пароль или ключ — скрыт, «Скопировать») и RDP (адрес, логин, «Открыть», «Скопировать
// адрес»). Не разобралось — соответствующие строки «Доступа» по «Показать», пароли в них под маской. Разбирает основной процесс;
// пароль или ключ сюда не приходит.
function howToCard(r, howto) {
  const card = el("div", "dcard howto");
  card.append(el("div", "dlbl", "КАК ПОДКЛЮЧИТЬСЯ"));
  if (r.needsVPN || howto.vpn) {
    const vpn = howto.vpn || { kind: null, server: null, login: null, hasSecret: false, lines: [] };
    const h = el("div", "dlbl vpn"); h.append(icon("shield"), "VPN");
    if (vpn.kind) h.append(el("span", "kind", vpn.kind));
    card.append(h);
    if (vpn.server || vpn.login || vpn.hasSecret) {
      if (vpn.server) card.append(fact("Сервер", vpn.server, true));
      if (vpn.login) card.append(fact("Логин", vpn.login));
      if (vpn.hasSecret) {
        const line = el("div", "fact"); line.append(el("span", "fk", "Пароль или ключ"));
        const dots = el("span", "dots", "••••••••"); dots.setAttribute("aria-hidden", "true");
        line.append(dots, el("span", "sp"), button("btn c sm", "Скопировать", () => window.rc.copySecret(r.key, "vpnSecret"), "Скопировать пароль VPN"));
        card.append(line);
      }
    } else if (vpn.lines.length) card.append(rawLines(vpn.lines));
    else card.append(el("small", "muted", r.accessLines > 0 ? "Профиль и ключ — в разделе «Доступ» ниже." : "Подробностей о VPN в файле нет."));
  }
  if (r.usesRDP || howto.rdp) {
    const rdp = howto.rdp || { address: null, login: null, canOpen: false, fromAccess: false, lines: [] };
    const h = el("div", "dlbl rdp"); h.append(icon("monitor"), "ПОДКЛЮЧЕНИЕ ЧЕРЕЗ RDP"); card.append(h);
    if (rdp.address) {
      const addr = el("div", "addr"); addr.append(el("b", null, rdp.address), el("span", null, "удалённый рабочий стол")); card.append(addr);
      if (rdp.login) card.append(fact("Логин", rdp.login));
      const acts = el("div", "dacts");
      if (rdp.canOpen) { const open = button("btn c pri", "Открыть в mstsc ⏎", () => openRDPFromDetails(r, rdp.fromAccess)); open.title = "Подключение к удалённому рабочему столу (mstsc)"; acts.append(open); }
      acts.append(button("btn c", "Скопировать адрес", () => window.rc.copyAddress(r.key, rdp.fromAccess)));
      card.append(acts);
      if (!rdp.canOpen) card.append(el("small", "muted", "Адрес не похож на имя или IP — откройте его вручную."));
    } else if (rdp.lines.length) card.append(rawLines(rdp.lines));
    else card.append(el("small", "muted", "Адрес — в разделе «Доступ»."));
  }
  return card;
}

// «Контакты»: люди и телефоны как в файле; у каждого телефона — «Скопировать». Только здесь: не в строке, не в поиске, не в журнале.
function contactsCard(contacts) {
  const card = el("div", "dcard");
  card.append(el("div", "dlbl", "КОНТАКТЫ"), el("div", "dnote", contacts.text));
  for (const phone of contacts.phones || []) {
    const line = el("div", "phone"); line.append(icon("phone"), el("span", "pn", phone), el("span", "sp"),
      button("btn c sm", "Скопировать", () => window.rc.copyPhone(phone), `Скопировать телефон ${phone}`));
    card.append(line);
  }
  return card;
}

// «Доступ · из файла»: вместо текста — размытые полосы (самого текста в окне нет), «Показать» читает его из файла.
function accessCard(r) {
  const card = el("div", "dcard access");
  const h = el("div", "dlbl row2"); const cap = el("span", null, "ДОСТУП · ИЗ ФАЙЛА");
  const toggle = button("btn c sm"), copy = button("btn c sm", "Скопировать", () => window.rc.copySecret(r.key, "access"));
  h.append(cap, toggle, copy);
  const pane = el("div", "apane");
  const caption = el("small", "muted", "Всё, что было на вкладке в Excel, без изменений. Не участвует в поиске и не пишется в журнал.");
  let shown = false;
  const conceal = (message) => {
    shown = false;
    pane.textContent = "";
    toggle.textContent = ""; toggle.append(icon("eye"), "Показать");
    const bars = el("div", "bars"); bars.setAttribute("aria-hidden", "true");
    const widths = [190, 240, 150, 120, 210, 230, 170, 140];
    for (let i = 0; i < Math.min(r.accessLines, 8); i++) { const b = el("i"); b.style.width = `${widths[i % 8]}px`; bars.append(b); }
    pane.append(bars, el("span", "veil", message || `${hiddenLines(r.accessLines)} · могут быть пароли`));
  };
  toggle.onclick = async () => {
    if (shown) return conceal();
    const res = await window.rc.revealAccess(r.key);
    if (!res || !res.ok || currentDetails !== r || !pane.isConnected) return pane.isConnected && conceal("Не удалось прочитать файл");
    shown = true;
    pane.textContent = "";
    // Переносы и пустые строки между блоками — как в файле (моноширинный, white-space: pre-wrap).
    pane.append(el("pre", "atext", res.text));
    toggle.textContent = ""; toggle.append(icon("eyeOff"), "Скрыть");
  };
  conceal();
  card.append(h, pane, caption);
  return card;
}

// ---- карточка записи: правка (.xml) или просмотр (.xlsx/.xlsm — правка в Excel, в книгу ничего не пишется) ----
const EDIT_ERRORS = { missingName: "Укажите название.", missingID: "Укажите ID.", invalidID: "ID должен быть из 9–10 цифр или вида имя@ad.", unknownProgram: "Неизвестная программа.",
  aliasNotSupported: "Алиас вида имя@ad работает только с AnyDesk.", gone: "Записи больше нет в файле — список обновлён.", writeFailed: "Не удалось сохранить файл. Копия .bak рядом.", corrupt: "Файл не читается как XML.", xlsxReadOnly: "Файлы .xlsx не правятся — только .xml." };
async function openEditorByKey(key) {
  const record = await window.rc.details(key);
  if (record) openEditor(record);
}
function openEditor(record) {
  const readOnly = !!record && !view.canEdit;
  if (!record && !view.canEdit) return;
  mode = "edit";
  $("page").hidden = true;
  $("detailsBox")?.remove();
  let box = $("editBox"); if (box) box.remove();
  box = el("div", "settings"); box.id = "editBox"; document.body.append(box);
  const inputs = {};
  const fileName = String(view.file || "").split(/[\\/]/).pop();
  const field = (key, label, value, { area = false, type = "text", placeholder = "" } = {}) => {
    const l = el("label", null, label); const i = el(area ? "textarea" : "input"); if (!area) i.type = type; else i.rows = 3;
    i.value = value || ""; i.placeholder = placeholder; i.disabled = readOnly; i.autocomplete = "off"; inputs[key] = i; l.append(i); return l;
  };
  const program = el("select"); program.disabled = readOnly;
  for (const [title, value] of [["По умолчанию", ""], ["AnyDesk", "AnyDesk"], ["TeamViewer", "TeamViewer"], ["RDP", "RDP"], ["VPN", "VPN"], ["Другое", "Другое"]]) program.append(new Option(title, value));
  program.value = record ? record.programChoice : "";
  const error = el("div", "banner danger"); error.hidden = true;
  const close = () => { inputs.accountPassword.value = ""; box.remove(); $("page").hidden = false; mode = "list"; refresh(); };
  const actions = el("div"); actions.style.cssText = "display:flex;gap:8px";
  let removeAccount = null;
  if (readOnly) {
    actions.append(button("btn pri", "Открыть в Excel", () => { window.rc.openFile(); close(); }), button("btn", "Закрыть", close));
  } else {
    const save = el("button", "btn pri", record ? "Сохранить" : "Добавить");
    save.onclick = async () => {
      const fields = { name: inputs.name.value, id: inputs.id.value, group: inputs.group.value, tags: inputs.tags.value, note: inputs.note.value, program: program.value, account: inputs.account.value };
      // Пароль учётки: пустое поле — в файле не меняется; «убрать» — пустая строка.
      if (inputs.accountPassword.value) fields.accountPassword = inputs.accountPassword.value;
      else if (removeAccount && removeAccount.checked) fields.accountPassword = "";
      const r = await window.rc.edit(record ? "update" : "add", { key: record && record.key, fields });
      inputs.accountPassword.value = "";
      if (r.ok) return close();
      error.textContent = EDIT_ERRORS[r.error] || "Не удалось сохранить."; error.hidden = false;
    };
    actions.append(save, button("btn", "Отмена", close));
    if (record) {
      const del = el("button", "btn dng", "Удалить"); let armed = false;
      del.onclick = async () => { if (!armed) { armed = true; del.textContent = "Точно удалить?"; return; } const r = await window.rc.edit("remove", { key: record.key }); if (r.ok) close(); else { error.textContent = EDIT_ERRORS[r.error] || "Не удалось удалить."; error.hidden = false; } };
      actions.append(del);
    }
  }
  const accountPw = field("accountPassword", "Пароль учётной записи", "", { type: "password",
    placeholder: readOnly ? (record.hasAccountPassword ? "Есть в файле" : "В файле нет") : record && record.hasAccountPassword ? "Не меняется" : "—" });
  if (!readOnly && record && record.hasAccountPassword) {
    const l = el("label", "inline"); removeAccount = el("input"); removeAccount.type = "checkbox"; l.append(removeAccount, document.createTextNode("Убрать пароль учётки из файла")); accountPw.append(l);
  }
  box.append(el("h2", null, readOnly ? "Запись" : record ? "Изменить запись" : "Добавить запись"),
    el("div", "muted", readOnly ? `${fileName} · правка — в Excel` : `${fileName} · правки записываются сразу в файл`), error,
    field("name", "Название", record && record.name), field("id", "ID, алиас (имя@ad) или адрес — для RDP, VPN и «Другое» необязателен", record && record.rawID),
    field("group", "Группа", record && record.group), field("tags", "Теги (через запятую)", record && record.tags), field("note", "Заметка", record && record.note, { area: true }),
    (() => { const l = el("label", null, "Программа"); l.append(program); return l; })(),
    field("account", "Учётная запись Windows (логин)", record && record.account), accountPw,
    el("div", "muted", readOnly ? "Правка — в Excel: изменения в таблице появятся здесь сами."
      : "Пароль программы здесь не показывается и не меняется; «Доступ» и «Контакты» в файле остаются как есть. Перед сохранением рядом создаётся копия .bak."),
    actions);
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
// Палитра показана снова — с чистого листа (подробности закрыты, поиск и фильтры сброшены).
window.rc.onShow(() => {
  if (mode === "settings" || mode === "edit") return;
  if (mode === "details") { $("detailsBox")?.remove(); detailsKey = null; currentDetails = null; currentCard = null; $("page").hidden = false; mode = "list"; }
  $("query").value = ""; filter = "all"; selectedTags.clear(); tagsExpanded = false; selected = 0; refresh(); $("query").focus();
});
// Окно скрыто или свёрнуто — показанный «Доступ» убирается (подробности перерисовываются без текста).
document.addEventListener("visibilitychange", () => { if (document.hidden && mode === "details") renderDetails(); });
// Меню строки (правая кнопка) — подробности или карточка записи.
window.rc.onMenu((m) => {
  if (!m || mode === "settings" || mode === "edit") return;
  if (m.action === "details") openDetails(m.key);
  else if (m.action === "edit") openEditorByKey(m.key);
});
// Подробности из трея (VPN, «Другое»): окно забирает ключ, когда готово.
const takePending = async () => { const key = await window.rc.pendingDetails(); if (key && mode !== "settings" && mode !== "edit") openDetails(key); };
window.rc.onDetails(takePending);
// Палитра: внизу только «Обновить» (↻). Excel, папка, «Добавить», настройки и строка «Загружено …» — в окне списка.
if (palette) { $("hints").hidden = false; for (const id of ["openFile", "folderBtn", "addBtn", "settingsBtn", "summary"]) $(id).hidden = true; }
refresh().then(() => { $("query").focus(); if (!palette) takePending(); });
