"use strict";
const $ = (id) => document.getElementById(id);
const ICONS = { info: "…", success: "✓", warning: "!", danger: "×" };
window.hud.onState((s) => {
  $("hud").className = `hud ${s.kind || "info"}`;
  $("ic").textContent = ICONS[s.kind] || "…";
  $("title").textContent = s.title || "";
  $("detail").textContent = s.detail || "";
  $("prog").hidden = typeof s.progress !== "number";
  if (typeof s.progress === "number") $("bar").style.width = `${Math.round(s.progress * 100)}%`;
  const acts = $("acts"); acts.textContent = "";
  for (const a of s.actions || []) { const b = document.createElement("button"); b.className = "btn c"; b.textContent = a.label; b.onclick = () => window.hud.action(a.id); acts.append(b); }
});
