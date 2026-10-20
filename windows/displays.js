// Мониторы ведущего для зрителей (SHARE-PROTOCOL §4.1, чистые функции; main.js и тесты — tests/displays.test.cjs).
// Зритель знает только номер монитора: имён устройств и их ID в списке нет. Нумерация одна на Mac и Windows — слева
// направо, затем сверху вниз (как «Screen 1, 2…» у Windows и overlay-place.js), проверяется общей фикстурой displays.json.
(function (exports) {
  const MAX_DISPLAYS = 8;
  const round2 = (v) => Math.round(v * 100) / 100;
  const clampPixels = (v) => Math.min(Math.max(Math.round(v), 1), 32768);

  // Мониторы Electron по порядку номеров: [{ display, n }].
  function numbered(displays) {
    return [...displays]
      .sort((a, b) => a.bounds.x - b.bounds.x || a.bounds.y - b.bounds.y)
      .slice(0, MAX_DISPLAYS)
      .map((display, i) => ({ display, n: i + 1 }));
  }

  // Список для `displays`: место на схеме — DIP (`bounds`), размер — физические пиксели (physOf), масштаб — scaleFactor.
  function list(displays, primary, physOf) {
    return numbered(displays).map(({ display, n }) => {
      const phys = physOf(display), b = display.bounds;
      return { n, primary: !!primary && display.id === primary.id, w: clampPixels(phys.width), h: clampPixels(phys.height),
               scale: round2(Math.min(Math.max(display.scaleFactor || 1, 0.5), 4)), at: [b.x, b.y, b.width, b.height] };
    });
  }

  // Номер монитора (0 — не монитор: окно или ничего не выбрано).
  function numberOf(display, displays) {
    if (!display) return 0;
    return numbered(displays).find((d) => d.display.id === display.id)?.n || 0;
  }

  // Источник desktopCapturer для монитора с номером n: по display_id, иначе по номеру в названии («Screen 2»,
  // «Экран 2» — тот же порядок слева направо).
  function sourceFor(n, sources, displays) {
    const target = numbered(displays).find((d) => d.n === n)?.display;
    if (!target) return null;
    const screens = sources.filter((s) => /^screen:/.test(s.id || ""));
    return screens.find((s) => String(s.display_id || "") === String(target.id))
      || screens.find((s) => !s.display_id && Number((/(\d+)\s*$/.exec(s.name || "") || [])[1]) === n)
      // Один монитор («Entire screen» без display_id) — он и есть.
      || (screens.length === 1 && displays.length === 1 ? screens[0] : null);
  }

  // Уведомление в окне меток: имя (как текст, не разметка) и номер; мини-схема — из того же списка.
  function notice(data) {
    if (!data || typeof data !== "object" || !Number.isInteger(data.n) || data.n < 1 || data.n > MAX_DISPLAYS) return null;
    const name = String(data.name ?? "").trim().slice(0, 60) || "Зритель";
    const shown = Array.isArray(data.list) ? data.list.filter((d) => d && Number.isInteger(d.n) && Array.isArray(d.at) && d.at.length === 4
      && d.at.every(Number.isFinite) && d.at[2] > 0 && d.at[3] > 0).slice(0, MAX_DISPLAYS) : [];
    return { name, n: data.n, list: shown.map((d) => ({ n: d.n, primary: !!d.primary, at: d.at.slice(0, 4) })) };
  }

  exports.MAX_DISPLAYS = MAX_DISPLAYS;
  exports.numbered = numbered;
  exports.list = list;
  exports.numberOf = numberOf;
  exports.sourceFor = sourceFor;
  exports.notice = notice;
})(typeof module !== "undefined" ? module.exports : (window.muDisplays = {}));
