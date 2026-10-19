// Где рисовать метки зрителей поверх экрана ведущего (чистые функции; main.js и overlay.html, тесты — tests/).
// Прямоугольники — в DIP Electron, как у screen.getAllDisplays(): { x, y, width, height }.
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

  // Окно меток накрывает весь монитор транслируемой области, а метки ставятся в неё саму. Так положение меток не
  // зависит от того, куда Windows на самом деле поставила окно меток (смена масштаба, монитор с другим DPI):
  // region — транслируемая область относительно фактического содержимого окна меток (CSS-пиксели = DIP).
  function region(target, content) {
    return { x: target.x - content.x, y: target.y - content.y, w: target.width, h: target.height };
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
  exports.region = region;
  exports.markPoint = markPoint;
  exports.same = same;
  exports.share = share;
})(typeof module !== "undefined" ? module.exports : (window.overlayPlace = {}));
