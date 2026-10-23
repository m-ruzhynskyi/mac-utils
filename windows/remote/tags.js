// Метки записи. «Рег», «рег.», «РЕГ» — одна метка; «фито» и «фіто» — тоже: сравнение без регистра, точек и пробелов,
// украинские буквы — как русские. VPN и RDP — не метки, а значки. 1:1 с Mac (`ConnectionTags.swift`).
"use strict";

const VPN = "vpn", RDP = "rdp";

// Ключ сравнения: нижний регистр, только буквы и цифры; і/ї → и, є → е, ґ → г, ё → е.
function tagKey(tag) {
  return String(tag).normalize("NFC").toLowerCase().replace(/[^\p{L}\p{M}\p{N}]/gu, "")
    .replace(/[іїєґё]/g, (c) => ({ і: "и", ї: "и", є: "е", ґ: "г", ё: "е" })[c] || "");
}

// "reg" | "phyto" | "other"
function tagKind(tag) {
  const k = tagKey(tag);
  return k === "рег" ? "reg" : k === "фито" ? "phyto" : "other";
}

// VPN и RDP показываются значками, а не метками.
const isBadgeTag = (tag) => { const k = tagKey(tag); return k === VPN || k === RDP; };

// Как показывать: «Рег» и «Фито» — единообразно, остальные — как в файле.
function displayTag(tag) {
  const kind = tagKind(tag);
  return kind === "reg" ? "Рег" : kind === "phyto" ? "Фито" : String(tag);
}

module.exports = { VPN, RDP, tagKey, tagKind, isBadgeTag, displayTag };
