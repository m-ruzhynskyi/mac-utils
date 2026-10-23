// Сервис модуля (без Electron): список, поиск, избранное/недавние, диагностика, подключение. Окна, трей и клавиши — в index.js.
// Наружу (в окна) уходит только то, что можно показывать: пароль сюда не попадает никогда.
"use strict";

const { ConnectionSearch, highlights, highlightsInID } = require("./search");
const lists = require("./lists");
const { programOf, displayID, columnLetter, duplicateCount, isClean, TITLES, PROGRAMS, METHOD_TITLES, needsVPN, usesRDP, labelsOf, favoriteKey } = require("./models");
const { tagKind, displayTag } = require("./tags");
const { rdpHost } = require("./rdp");

// Выбор «Программа» в карточке записи: как записать в файл.
const PROGRAM_CHOICE = { anyDesk: "AnyDesk", teamViewer: "TeamViewer", rdp: "RDP", vpn: "VPN", other: "Другое" };

class RemoteService {
  // deps: { settings: RemoteSettings, store: ConnectionsFileStore, connector?: { installed(program), connect(record, program, opts) } }
  constructor({ settings, store, connector = null }) {
    this.settings = settings;
    this.store = store;
    this.connector = connector;
    this.search = new ConnectionSearch([]);
    this.indexed = null;
    store.on("change", () => this.emit());
    this.listeners = new Set();
  }

  onChange(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  emit() { for (const fn of this.listeners) { try { fn(); } catch (_) {} } }

  start() { this.store.setSource(this.settings.data.file, this.settings.data.sheet); }

  records() { return this.store.state.snapshot?.records ?? []; }

  index() {
    const snapshot = this.store.state.snapshot;
    if (this.indexed !== snapshot) { this.search = new ConnectionSearch(snapshot?.records ?? []); this.indexed = snapshot; }
    return this.search;
  }

  // Что показывать в окне и в палитре. filter: "all" | "anyDesk" | "teamViewer" | "rdp" | "vpn"; tags — ключи выбранных меток.
  // Секретов (пароль, пароль учётки, «Доступ») и контактов здесь нет: только признаки и число строк «Доступа».
  view({ query = "", filter = "all", tags = [] } = {}) {
    const s = this.settings.data, state = this.store.state;
    const installed = Object.fromEntries(PROGRAMS.map((p) => [p, this.connector ? this.connector.installed(p) : true]));
    const base = { status: state.status, error: state.error && { code: state.error.code, found: state.error.found || [], detail: state.error.code === "corrupt" ? state.error.detail : "" },
      installed, defaultProgram: s.defaultProgram, titles: TITLES, file: s.file, hotkey: s.hotkey, canEdit: /\.xml$/i.test(s.file),
      // Карточку записи можно открыть: в .xml — править, в .xlsx/.xlsm — только смотреть (правка — в Excel).
      canView: /\.(xml|xlsx|xlsm)$/i.test(s.file) };
    if (state.status !== "ready" || !state.snapshot) return { ...base, sections: [], counts: { all: 0, anyDesk: 0, teamViewer: 0, rdp: 0, vpn: 0 }, tags: [], hint: null, query, diagnostics: null };
    const listing = lists.buildListing({ search: this.index(), query, filter: lists.FILTERS.includes(filter) ? filter : "all", defaultProgram: s.defaultProgram,
      favorites: s.favoriteIDs, recents: s.recentIDs, tags: (Array.isArray(tags) ? tags : []).filter((t) => typeof t === "string" && t).slice(0, 50) });
    const effective = listing.effectiveQuery;
    const present = (record, sectionID) => this.present(record, sectionID, effective, installed);
    const records = state.snapshot.records;
    return { ...base, hint: listing.hint, counts: listing.counts, tags: listing.tags, query,
      diagnostics: { ...this.diagnosticsView(state.snapshot.diagnostics), vpn: records.filter(needsVPN).length, rdp: records.filter(usesRDP).length },
      sections: listing.sections.map((sec) => ({ id: sec.id, kind: sec.kind, title: sec.title || "", records: sec.records.map((r) => present(r, sec.id)) })) };
  }

  // Запись для окна: всё, что видно в строке и в подробностях. effective — запрос для подсветки.
  present(record, sectionID = "", effective = "", installed = null) {
    const s = this.settings.data;
    installed = installed || Object.fromEntries(PROGRAMS.map((p) => [p, this.connector ? this.connector.installed(p) : true]));
    const method = record.method || null;
    const program = method ? null : programOf(record, s.defaultProgram);
    const shownID = displayID(record);
    const noteLine = record.note.split(/\r\n|[\n\r\u2028\u2029]/).map((l) => l.trim()).filter(Boolean).join(" ");
    const mark = (text) => (effective && text ? highlights(text, effective) : []);
    return {
      rowID: `${sectionID}|${record.sourceRow}:${record.id}`, key: `${record.sourceRow}:${record.id}`, rawID: record.id, name: record.name, id: shownID,
      group: record.group, note: record.note, noteLine, tags: record.tags.join(", "),
      labels: labelsOf(record).map((t) => ({ title: displayTag(t), kind: tagKind(t) })),
      method, methodTitle: method ? METHOD_TITLES[method] : "", program, programTitle: program ? TITLES[program] : METHOD_TITLES[method],
      programFile: record.program || "", programChoice: PROGRAM_CHOICE[method || record.program] || "",
      needsVPN: needsVPN(record), usesRDP: usesRDP(record), rdpHost: rdpHost(record),
      account: record.account || "", hasAccountPassword: !!record.hasAccountPassword, accessLines: record.accessLines || 0, hasContacts: !!record.hasContacts,
      hasPassword: record.hasPassword, favorite: lists.isFavorite(record, s), favoriteKey: favoriteKey(record), dim: program ? !installed[program] : false,
      nameMarks: mark(record.name), idMarks: effective && shownID ? highlightsInID(shownID, effective) : [], accountMarks: mark(record.account), noteMarks: mark(noteLine),
    };
  }

  // Одна запись для подробностей (после перечитывания файла — та же запись или null).
  details(key) {
    const record = this.recordByKey(key);
    return record ? this.present(record, "details") : null;
  }

  // Секрет записи из файла сейчас (пароль учётки, «Доступ», «Контакты»). SecretBuffer или null; вызывающий затирает.
  async secret(key, field) {
    const record = this.recordByKey(key);
    if (!record || !["accountPassword", "access", "contacts"].includes(field)) return null;
    return this.store.secret(record, field);
  }

  // Диагностика — строка внизу списка, раскрывается в самом списке (отдельного окна нет).
  diagnosticsView(d) {
    return {
      loaded: d.loaded, withPassword: d.withPassword, skippedCount: d.skipped.length, duplicateCount: duplicateCount(d), clean: isClean(d),
      columns: d.columns.map((c) => ({ title: c.title, field: c.field, letter: columnLetter(c.column) })),
      skipped: d.skipped, duplicates: d.duplicates, unrecognizedColumns: d.unrecognizedColumns, lossyIDRows: d.lossyIDRows, ambiguousProgramRows: d.ambiguousProgramRows,
    };
  }

  recordByKey(key) { return this.records().find((r) => `${r.sourceRow}:${r.id}` === key) || null; }

  toggleFavorite(key) {
    const record = this.recordByKey(key);
    if (!record) return false;
    const prefs = { favoriteIDs: [...this.settings.favoriteIDs], recentIDs: this.settings.recentIDs };
    lists.toggleFavorite(record, prefs);
    this.settings.favoriteIDs = prefs.favoriteIDs;
    this.emit();
    return true;
  }

  noteConnected(record) {
    const prefs = { favoriteIDs: this.settings.favoriteIDs, recentIDs: [...this.settings.recentIDs] };
    lists.noteConnected(record, prefs);
    this.settings.recentIDs = prefs.recentIDs;
    this.emit();
  }
}

module.exports = { RemoteService };
