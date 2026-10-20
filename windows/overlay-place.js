// Где рисовать метки зрителей поверх экрана ведущего (чистые функции; main.js и overlay.html, тесты — tests/).
// Прямоугольники — в ФИЗИЧЕСКИХ пикселях Windows: { x, y, width, height }. DIP Electron здесь не участвуют: на мониторах
// с разным масштабом окно меток живёт с DPI не своего монитора, и DIP-арифметика уводит метки (журнал 1.1.17).
// Точка зрителя — доля кадра трансляции от левого верхнего угла (0…1), кадр — ровно транслируемая область.
(function (exports) {
  // Транслируемый монитор: по display_id источника, иначе по номеру в названии («Screen 2»), иначе основной.
  // Окно (id «window:…») — null: где оно, говорит помощник (track).
  function sharedDisplay(source, displays, primary) {
    if (/^window:/.test(source?.id || "")) return null;
    const byId = displays.find((d) => String(d.id) === String(source?.display_id || ""));
    if (byId) return byId;
    const index = /^screen:/.test(source?.id || "") ? Number((/(\d+)\s*$/.exec(source.name || "") || [])[1]) : NaN;
    if (index >= 1 && index <= displays.length) {
      // Порядок «Screen 1, 2…» у Windows — слева направо, как у мониторов по координатам.
      return [...displays].sort((a, b) => a.bounds.x - b.bounds.x || a.bounds.y - b.bounds.y)[index - 1];
    }
    return primary;
  }

  const overlap = (a, b) => Math.max(0, Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x)) *
    Math.max(0, Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y));

  // Монитор (физическая рамка), на котором большая часть области; область вне всех мониторов — ближайший по центру.
  function monitorOf(rect, monitors) {
    const center = (r) => [r.x + r.width / 2, r.y + r.height / 2];
    const [cx, cy] = center(rect);
    const distance = (m) => { const [mx, my] = center(m); return (mx - cx) ** 2 + (my - cy) ** 2; };
    return [...monitors].sort((a, b) => overlap(b, rect) - overlap(a, rect) || distance(a) - distance(b))[0] || null;
  }

  // Окно меток стоит ровно на мониторе области, поэтому область передаётся странице долями монитора (= долями окна
  // меток): страница умножает их на свои innerWidth/innerHeight, и результат не зависит от её devicePixelRatio.
  function fractions(target, monitor) {
    return { fx: (target.x - monitor.x) / monitor.width, fy: (target.y - monitor.y) / monitor.height,
             fw: target.width / monitor.width, fh: target.height / monitor.height };
  }

  // Доли → область на холсте страницы меток (CSS-пиксели её окна).
  function areaIn(fr, width, height) {
    return { x: fr.fx * width, y: fr.fy * height, w: fr.fw * width, h: fr.fh * height };
  }

  // Точка зрителя → точка на холсте окна меток.
  function markPoint(point, area) {
    return [area.x + point[0] * area.w, area.y + point[1] * area.h];
  }

  // Где точка `drawn` (физические пиксели) в захваченной области `capture` (физические пиксели), в долях. Совпадает
  // с точкой зрителя — метка у ведущего на месте; нет — видно, на сколько и куда она ушла.
  function share(drawn, capture) {
    return [(drawn.x - capture.x) / capture.width, (drawn.y - capture.y) / capture.height];
  }

  const same = (a, b) => !!a && !!b && a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;

  exports.sharedDisplay = sharedDisplay;
  exports.monitorOf = monitorOf;
  exports.fractions = fractions;
  exports.areaIn = areaIn;
  exports.markPoint = markPoint;
  exports.same = same;
  exports.share = share;
})(typeof module !== "undefined" ? module.exports : (window.overlayPlace = {}));
