// Сервис модуля (без Electron): список, поиск, избранное/недавние, диагностика, подключение. Окна, трей и клавиши — в index.js.
// Наружу (в окна) уходит только то, что можно показывать: пароль сюда не попадает никогда.
"use strict";

const { ConnectionSearch, highlights, highlightsInID } = require("./search");
const lists = require("./lists");
const { programOf, displayID, columnLetter, duplicateCount, isClean, TITLES, PROGRAMS } = require("./models");

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

  // Что показывать в окне и в палитре. filter: "all" | "anyDesk" | "teamViewer".
  view({ query = "", filter = "all" } = {}) {
    const s = this.settings.data, state = this.store.state;
    const installed = Object.fromEntries(PROGRAMS.map((p) => [p, this.connector ? this.connector.installed(p) : true]));
    const base = { status: state.status, error: state.error && { code: state.error.code, found: state.error.found || [], detail: state.error.code === "corrupt" ? state.error.detail : "" },
      installed, defaultProgram: s.defaultProgram, titles: TITLES, file: s.file, hotkey: s.hotkey };
    if (state.status !== "ready" || !state.snapshot) return { ...base, sections: [], counts: { all: 0, anyDesk: 0, teamViewer: 0 }, hint: null, query, diagnostics: null };
    const listing = lists.buildListing({ search: this.index(), query, filter, defaultProgram: s.defaultProgram, favorites: s.favoriteIDs, recents: s.recentIDs });
    const effective = listing.effectiveQuery;
    const present = (record, sectionID) => {
      const program = programOf(record, s.defaultProgram);
      const shownID = displayID(record);
      return {
        rowID: `${sectionID}|${record.sourceRow}:${record.id}`, key: `${record.sourceRow}:${record.id}`, name: record.name, id: shownID, group: record.group, note: record.note,
        program, programTitle: TITLES[program], hasPassword: record.hasPassword, favorite: lists.isFavorite(record, s), dim: !installed[program],
        nameMarks: effective ? highlights(record.name, effective) : [], idMarks: effective ? highlightsInID(shownID, effective) : [],
      };
    };
    return { ...base, hint: listing.hint, counts: listing.counts, query, diagnostics: this.diagnosticsView(state.snapshot.diagnostics),
      sections: listing.sections.map((sec) => ({ id: sec.id, kind: sec.kind, title: sec.title || "", records: sec.records.map((r) => present(r, sec.id)) })) };
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
