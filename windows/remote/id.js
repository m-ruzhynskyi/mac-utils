// Нормализация ID: число, текст с пробелами, 1.23E+08, 123456789.0, алиас name@ad. 1:1 с Mac (`ConnectionID.swift`).
"use strict";

// Невидимые знаки, которые приносит копирование из мессенджеров и веба.
const INVISIBLE = /[​‌‍⁠﻿]/g;

// {value, lossy, isAlias} или null — значение не похоже на ID. Пустую строку вызывающий обрабатывает отдельно.
function normalize(raw) {
  const s = String(raw).replace(/\s/g, "").replace(INVISIBLE, "");
  if (!s) return null;
  if (s.includes("@")) {
    const value = alias(s);
    return value ? { value, lossy: false, isAlias: true } : null;
  }
  const n = number(s);
  return n ? { ...n, isAlias: false } : null;
}

function alias(s) {
  const parts = s.split("@");
  if (parts.length !== 2 || !parts[0] || !parts[1]) return null;
  const ok = (part) => /^[A-Za-z0-9._-]+$/.test(part);
  return ok(parts[0]) && ok(parts[1]) ? s.toLowerCase() : null;
}

function number(s) {
  let mantissa = s.toLowerCase();
  // «1,23E+08» — так экспоненту пишет Excel с русской или украинской локалью.
  if (mantissa.includes("e")) mantissa = mantissa.replace(/,/g, ".");
  let exponent = 0, hasExponent = false;
  const e = mantissa.indexOf("e");
  if (e >= 0) {
    const tail = mantissa.slice(e + 1).replace("+", "");
    if (!/^-?\d+$/.test(tail)) return null;
    exponent = parseInt(tail, 10);
    if (Math.abs(exponent) > 30) return null;
    hasExponent = true;
    mantissa = mantissa.slice(0, e);
  }
  const halves = mantissa.split(".");
  if (halves.length > 2) return null;
  const whole = halves[0];
  if (!whole && halves.length !== 2) return null;
  const fraction = halves.length === 2 ? halves[1] : "";
  if (!/^[0-9]+$/.test(whole + fraction)) return null;
  let digits = (whole + fraction).split("");
  const point = whole.length + exponent;
  if (point < 0) return null;
  if (point >= digits.length) {
    while (digits.length < point) digits.push("0");
  } else {
    // Дробная часть допустима, только если она нулевая (123456789.0).
    if (!digits.slice(point).every((d) => d === "0")) return null;
    digits = digits.slice(0, point);
  }
  let text = digits.join("");
  // Нули слева у «чистого» текста — часть ID; у числа с точкой или экспонентой — артефакт записи.
  if (hasExponent || halves.length === 2) text = text.replace(/^0+(?=.)/, "");
  if (text.length < 9 || text.length > 10) return null;
  // Экспонента дописала нули: в 1.23E+08 цифр меньше, чем в ID.
  return { value: text, lossy: hasExponent && (whole.length + fraction.length) < text.length };
}

module.exports = { normalize };
