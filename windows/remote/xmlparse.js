// Небольшой потоковый разбор XML: теги, атрибуты, текст, CDATA, комментарии, <?…?>, <!DOCTYPE …> (пропускается: внешние
// и пользовательские сущности не раскрываются). Номер строки — для диагностики XML и сообщений об ошибках.
"use strict";

const { ConnectionsError } = require("./models");

const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
function decode(text) {
  if (!text.includes("&")) return text;
  return text.replace(/&(#x[0-9a-fA-F]+|#\d+|[A-Za-z]+);/g, (whole, body) => {
    if (body[0] === "#") {
      const code = body[1] === "x" || body[1] === "X" ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      return Number.isFinite(code) && code > 0 && code <= 0x10FFFF ? String.fromCodePoint(code) : "";
    }
    return Object.hasOwn(ENTITIES, body) ? ENTITIES[body] : "";   // чужие сущности не раскрываем
  });
}

const localName = (name) => name.slice(name.lastIndexOf(":") + 1);

// handler: { start(name, attrs, line), end(name), text(text), cdata(text) } — name без префикса пространства имён.
// Бросает ConnectionsError corrupt при нарушении вложенности и обрывах.
function parse(input, handler, { maxDepth = 64 } = {}) {
  const s = Buffer.isBuffer(input) ? input.toString("utf8").replace(/^﻿/, "") : String(input);
  const stack = [];
  let i = 0, line = 1;
  const fail = (what) => { throw new ConnectionsError("corrupt", `${what} (строка ${line})`); };
  const lineTo = (end) => { for (let k = i; k < end; k++) if (s.charCodeAt(k) === 10) line++; };
  while (i < s.length) {
    const lt = s.indexOf("<", i);
    if (lt < 0) { const rest = s.slice(i); if (stack.length && rest.trim()) handler.text?.(decode(rest)); else if (rest.trim()) fail("Текст вне корня"); lineTo(s.length); i = s.length; break; }
    if (lt > i) { const t = s.slice(i, lt); if (stack.length) handler.text?.(decode(t)); else if (t.trim()) fail("Текст вне корня"); lineTo(lt); i = lt; }
    if (s.startsWith("<!--", i)) { const e = s.indexOf("-->", i + 4); if (e < 0) fail("Не закрыт комментарий"); lineTo(e + 3); i = e + 3; continue; }
    if (s.startsWith("<![CDATA[", i)) {
      const e = s.indexOf("]]>", i + 9); if (e < 0) fail("Не закрыт CDATA");
      if (stack.length) handler.cdata?.(s.slice(i + 9, e));
      lineTo(e + 3); i = e + 3; continue;
    }
    if (s.startsWith("<?", i)) { const e = s.indexOf("?>", i + 2); if (e < 0) fail("Не закрыта инструкция"); lineTo(e + 2); i = e + 2; continue; }
    if (s.startsWith("<!", i)) {
      // DOCTYPE: пропускаем целиком, включая внутреннюю часть [ … ].
      let depth = 0, k = i + 2;
      for (; k < s.length; k++) { const c = s[k]; if (c === "[") depth++; else if (c === "]") depth--; else if (c === ">" && depth <= 0) break; }
      if (k >= s.length) fail("Не закрыта декларация");
      lineTo(k + 1); i = k + 1; continue;
    }
    if (s[i + 1] === "/") {
      const e = s.indexOf(">", i); if (e < 0) fail("Не закрыт тег");
      const name = localName(s.slice(i + 2, e).trim());
      if (!stack.length || stack[stack.length - 1] !== name) fail("Нарушена вложенность тегов");
      stack.pop(); handler.end?.(name);
      lineTo(e + 1); i = e + 1; continue;
    }
    // Открывающий тег: имя, атрибуты в кавычках, необязательный «/».
    const tagLine = line;
    let k = i + 1;
    while (k < s.length && !/[\s/>]/.test(s[k])) k++;
    const name = localName(s.slice(i + 1, k));
    if (!name) fail("Пустое имя тега");
    const attrs = {};
    let selfClose = false;
    for (;;) {
      while (k < s.length && /\s/.test(s[k])) k++;
      if (k >= s.length) fail("Не закрыт тег");
      if (s[k] === ">") { k++; break; }
      if (s[k] === "/" && s[k + 1] === ">") { selfClose = true; k += 2; break; }
      const a = k;
      while (k < s.length && !/[\s=/>]/.test(s[k])) k++;
      const attr = s.slice(a, k);
      while (k < s.length && /\s/.test(s[k])) k++;
      if (!attr || s[k] !== "=") fail("Некорректный атрибут");
      k++;
      while (k < s.length && /\s/.test(s[k])) k++;
      const quote = s[k];
      if (quote !== '"' && quote !== "'") fail("Значение атрибута без кавычек");
      const close = s.indexOf(quote, k + 1);
      if (close < 0) fail("Не закрыто значение атрибута");
      attrs[attr] = decode(s.slice(k + 1, close));
      k = close + 1;
    }
    if (stack.length >= maxDepth) fail("Слишком глубокая вложенность");
    lineTo(k); i = k;
    stack.push(name); handler.start?.(name, attrs, tagLine);
    if (selfClose) { stack.pop(); handler.end?.(name); }
  }
  if (stack.length) fail("Не закрыт тег " + stack[stack.length - 1]);
}

module.exports = { parse, decode };
