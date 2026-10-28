// Выбор экрана или окна на странице ретранслятора (чистые функции; main.js и tests/guard.test.cjs).
// Снимков экрана и окон страница не получает: у экрана вместо снимка — схема мониторов ведущего с этим монитором и его
// номером (только геометрия, как у списка мониторов для зрителей), у окна — значок окна. Название источника остаётся.
// Картинка — data:-адрес SVG без кавычек (encodeURIComponent): страница вставляет его в <img src="…">.
const place = require("./overlay-place");
const monitorsList = require("./displays");

const W = 400, H = 225, PAD = 24;
const svg = (body) => `data:image/svg+xml,${encodeURIComponent(`<svg xmlns='http://www.w3.org/2000/svg' width='${W}' height='${H}' viewBox='0 0 ${W} ${H}'><rect width='${W}' height='${H}' rx='10' fill='#1F2329'/>${body}</svg>`)}`;
const r1 = (v) => Math.round(v * 10) / 10;

// Схема мониторов: все мониторы по их месту (DIP), выбранный — лайм, на каждом номер.
function screenPicture(display, displays) {
  const all = monitorsList.numbered(displays);
  if (!all.length) return svg("");
  const minX = Math.min(...all.map(({ display: d }) => d.bounds.x)), minY = Math.min(...all.map(({ display: d }) => d.bounds.y));
  const maxX = Math.max(...all.map(({ display: d }) => d.bounds.x + d.bounds.width));
  const maxY = Math.max(...all.map(({ display: d }) => d.bounds.y + d.bounds.height));
  const k = Math.min((W - 2 * PAD) / Math.max(maxX - minX, 1), (H - 2 * PAD) / Math.max(maxY - minY, 1));
  const dx = (W - (maxX - minX) * k) / 2, dy = (H - (maxY - minY) * k) / 2;
  const tiles = all.map(({ display: d, n }) => {
    const on = !!display && d.id === display.id;
    const x = r1(dx + (d.bounds.x - minX) * k + 3), y = r1(dy + (d.bounds.y - minY) * k + 3);
    const w = r1(Math.max(8, d.bounds.width * k - 6)), h = r1(Math.max(8, d.bounds.height * k - 6));
    const size = Math.round(Math.max(12, Math.min(48, h * 0.4)));
    return `<rect x='${x}' y='${y}' width='${w}' height='${h}' rx='6' fill='${on ? "#C8F05A" : "#2A2F37"}'/>` +
      `<text x='${r1(x + w / 2)}' y='${r1(y + h / 2)}' fill='${on ? "#10140A" : "#9AA3AF"}' font-family='Segoe UI,sans-serif' font-weight='700' ` +
      `font-size='${size}' text-anchor='middle' dominant-baseline='central'>${n}</text>`;
  });
  return svg(tiles.join(""));
}

const WINDOW_PICTURE = svg("<rect x='110' y='52' width='180' height='121' rx='8' fill='#2A2F37'/><rect x='110' y='52' width='180' height='22' rx='8' fill='#3A404A'/>" +
  "<rect x='110' y='66' width='180' height='8' fill='#3A404A'/><circle cx='124' cy='63' r='4' fill='#9AA3AF'/><circle cx='138' cy='63' r='4' fill='#9AA3AF'/>");

// sources — desktopCapturer.getSources; displays и primary — screen.getAllDisplays() и getPrimaryDisplay().
function entries(sources, displays, primary) {
  return sources.map((s) => ({
    id: s.id,
    name: s.name,
    thumbnail: /^screen:/.test(s.id || "") ? screenPicture(place.sharedDisplay(s, displays, primary), displays) : WINDOW_PICTURE,
  }));
}

module.exports = { entries, screenPicture, WINDOW_PICTURE };
