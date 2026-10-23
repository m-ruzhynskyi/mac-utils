// Избранное и недавние — по ID, без паролей; секции списка, фильтр по программе. 1:1 с Mac (`ConnectionLists.swift`).
"use strict";

const { PROGRAMS, programOf, identity } = require("./models");

const RECENT_LIMIT = 5;

// store: { favoriteIDs: string[], recentIDs: string[] } (хранит приложение).
const isFavorite = (record, store) => store.favoriteIDs.includes(record.id);
function toggleFavorite(record, store) {
  const i = store.favoriteIDs.indexOf(record.id);
  if (i >= 0) store.favoriteIDs.splice(i, 1); else store.favoriteIDs.push(record.id);
}
// После подключения: ID — первым в «Недавних», не больше пяти.
function noteConnected(record, store) {
  store.recentIDs = [record.id, ...store.recentIDs.filter((id) => id !== record.id)].slice(0, RECENT_LIMIT);
}

// Без запроса: «Избранное», «Недавние» (до 5), затем группы в порядке файла и «Без группы». С запросом: один список по
// релевантности. Фильтр по программе ("all" | "anyDesk" | "teamViewer") применяется ко всему. Исчезнувшие ID не показываются.
function buildListing({ search, query, filter, defaultProgram, favorites, recents }) {
  const result = search.search(query);
  const counts = { all: result.records.length };
  for (const p of PROGRAMS) counts[p] = 0;
  for (const r of result.records) counts[programOf(r, defaultProgram)]++;
  const visible = filter === "all" ? result.records : result.records.filter((r) => programOf(r, defaultProgram) === filter);
  const sections = [];
  if (result.effectiveQuery) sections.push({ id: "results", kind: "results", records: visible });
  else {
    const byKey = new Map();
    for (const r of visible) { if (!byKey.has(r.id)) byKey.set(r.id, []); byKey.get(r.id).push(r); }
    const fav = favorites.flatMap((id) => byKey.get(id) || []);
    if (fav.length) sections.push({ id: "favorites", kind: "favorites", records: fav });
    const seen = new Set();
    const recent = recents.filter((id) => byKey.has(id) && !seen.has(id) && seen.add(id)).slice(0, RECENT_LIMIT).flatMap((id) => byKey.get(id));
    if (recent.length) sections.push({ id: "recents", kind: "recents", records: recent });
    const order = [], groups = new Map(), ungrouped = [];
    for (const r of visible) {
      if (!r.group) { ungrouped.push(r); continue; }
      if (!groups.has(r.group)) { order.push(r.group); groups.set(r.group, []); }
      groups.get(r.group).push(r);
    }
    for (const g of order) sections.push({ id: `group:${g}`, kind: "group", title: g, records: groups.get(g) });
    if (ungrouped.length) sections.push({ id: "ungrouped", kind: "ungrouped", records: ungrouped });
  }
  // Плоский порядок для стрелок: запись может стоять и в «Избранном», и в группе — это разные строки.
  const rows = sections.flatMap((s) => s.records.map((record) => ({ sectionID: s.id, record, id: `${s.id}|${identity(record)}` })));
  return { sections, counts, hint: result.hint, effectiveQuery: result.effectiveQuery, rows, isEmpty: sections.every((s) => !s.records.length) };
}

module.exports = { RECENT_LIMIT, isFavorite, toggleFavorite, noteConnected, buildListing };
