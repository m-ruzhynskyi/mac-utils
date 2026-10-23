// Избранное и недавние — по ID (без ID — по названию), без паролей; секции списка, фильтр по программе и по меткам.
// 1:1 с Mac (`ConnectionLists.swift`).
"use strict";

const { PROGRAMS, programOf, identity, favoriteKey, needsVPN, usesRDP, labelsOf } = require("./models");
const { tagKey, tagKind, displayTag } = require("./tags");

const RECENT_LIMIT = 5;
const FILTERS = ["all", ...PROGRAMS, "rdp", "vpn"];

// store: { favoriteIDs: string[], recentIDs: string[] } (хранит приложение).
const isFavorite = (record, store) => store.favoriteIDs.includes(favoriteKey(record));
function toggleFavorite(record, store) {
  const key = favoriteKey(record);
  const i = store.favoriteIDs.indexOf(key);
  if (i >= 0) store.favoriteIDs.splice(i, 1); else store.favoriteIDs.push(key);
}
// После подключения: ключ — первым в «Недавних», не больше пяти.
function noteConnected(record, store) {
  const key = favoriteKey(record);
  store.recentIDs = [key, ...store.recentIDs.filter((id) => id !== key)].slice(0, RECENT_LIMIT);
}

// Фильтр-чип: "all" | "anyDesk" | "teamViewer" — программа (записи RDP/VPN/«Другое» к ним не относятся); "rdp" | "vpn" — способ
// или метка.
function matchesFilter(record, filter, defaultProgram) {
  if (filter === "rdp") return usesRDP(record);
  if (filter === "vpn") return needsVPN(record);
  if (PROGRAMS.includes(filter)) return !record.method && programOf(record, defaultProgram) === filter;
  return true;
}

// Без запроса: «Избранное», «Недавние» (до 5), затем группы в порядке файла и «Без группы». С запросом: один список по
// релевантности. Фильтр по программе применяется ко всему; метки (tags — ключи tagKey) — все выбранные сразу, вместе с фильтром
// программы. Исчезнувшие ID не показываются.
function buildListing({ search, query, filter, defaultProgram, favorites, recents, tags = [] }) {
  const result = search.search(query);
  const counts = { all: result.records.length, rdp: 0, vpn: 0 };
  for (const p of PROGRAMS) counts[p] = 0;
  for (const r of result.records) {
    if (!r.method) counts[programOf(r, defaultProgram)]++;
    if (usesRDP(r)) counts.rdp++;
    if (needsVPN(r)) counts.vpn++;
  }
  const byProgram = result.records.filter((r) => matchesFilter(r, filter, defaultProgram));
  const selected = new Set(tags);
  const visible = selected.size ? byProgram.filter((r) => { const own = new Set(labelsOf(r).map(tagKey)); return [...selected].every((k) => own.has(k)); }) : byProgram;
  const sections = [];
  if (result.effectiveQuery) sections.push({ id: "results", kind: "results", records: visible });
  else {
    const byKey = new Map();
    for (const r of visible) { const k = favoriteKey(r); if (!byKey.has(k)) byKey.set(k, []); byKey.get(k).push(r); }
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
  return { sections, counts, hint: result.hint, effectiveQuery: result.effectiveQuery, rows, isEmpty: sections.every((s) => !s.records.length),
    tags: tagCounts(byProgram, selected) };
}

// Метки по записям после поиска и фильтра программы: «Рег», «Фито», затем по частоте (при равенстве — по порядку в файле).
// Выбранные остаются в строке, даже если их стало 0. [{key, title, kind, count}]
function tagCounts(records, selected = new Set()) {
  const count = new Map(), title = new Map(), order = [];
  for (const r of records) {
    for (const tag of labelsOf(r)) {
      const k = tagKey(tag);
      if (!count.has(k)) { order.push(k); title.set(k, displayTag(tag)); count.set(k, 0); }
      count.set(k, count.get(k) + 1);
    }
  }
  for (const k of selected) {
    if (count.has(k)) continue;
    order.push(k); count.set(k, 0); title.set(k, k === "рег" ? "Рег" : k === "фито" ? "Фито" : k);
  }
  const rank = (k) => (k === "рег" ? 0 : k === "фито" ? 1 : 2);
  const position = new Map(order.map((k, i) => [k, i]));
  return [...order].sort((a, b) => rank(a) - rank(b) || count.get(b) - count.get(a) || position.get(a) - position.get(b))
    .map((k) => ({ key: k, title: title.get(k), kind: tagKind(title.get(k)), count: count.get(k) }));
}

module.exports = { RECENT_LIMIT, FILTERS, isFavorite, toggleFavorite, noteConnected, buildListing, matchesFilter, tagCounts };
