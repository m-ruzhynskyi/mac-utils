// Текст, набранный не в той раскладке: QWERTY ↔ ЙЦУКЕН (русская и украинская), по положению клавиш. 1:1 с Mac (`KeyboardLayouts.swift`).
"use strict";

const zip = (a, b) => { const m = new Map(); [...a].forEach((ch, i) => { if (!m.has(ch)) m.set(ch, [...b][i]); }); return m; };
const RU = zip("qwertyuiop[]asdfghjkl;'zxcvbnm,.`", "йцукенгшщзхъфывапролджэячсмитьбюё");
const UK = zip("qwertyuiop[]asdfghjkl;'zxcvbnm,.`\\", "йцукенгшщзхїфівапролджєячсмитьбюʼґ");
const EN = (() => {
  const m = new Map();
  for (const [en, ru] of RU) if (!m.has(ru)) m.set(ru, en);
  for (const [en, uk] of UK) if (!m.has(uk)) m.set(uk, en);
  m.set("'", "`"); m.set("’", "`");
  return m;
})();

const convert = (text, map) => [...text].map((ch) => map.get(ch) ?? ch).join("");

// Варианты запроса в других раскладках (в нижнем регистре); только те, что отличаются от исходного.
function alternatives(text) {
  const lower = text.toLowerCase();
  let latin = 0, cyrillic = 0;
  for (const ch of lower) {
    const c = ch.codePointAt(0);
    if (c >= 0x61 && c <= 0x7A) latin++; else if (c >= 0x400 && c <= 0x4FF) cyrillic++;
  }
  const targets = cyrillic > latin ? [EN] : latin > 0 ? [RU, UK] : [];
  const out = [];
  for (const map of targets) { const converted = convert(lower, map); if (converted !== lower && !out.includes(converted)) out.push(converted); }
  return out;
}

module.exports = { alternatives, convert, RU, UK, EN };
