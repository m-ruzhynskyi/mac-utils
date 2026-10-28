// Метки зрителей перед окном меток (чистые функции; main.js и tests/guard.test.cjs). Страница пересылает то, что
// пришло от relay; relay уже чистит метки, но приложение не полагается на это: метка пересобирается из проверенных
// полей (как sanitizeMark в relay/src/index.js), точек не больше MAX_POINTS, меток не больше MAX_PER_SECOND.
const COLORS = new Set(["red", "yellow", "green", "blue", "white"]);
const MAX_POINTS = 2000;
const MAX_PER_SECOND = 30;

const unit = (v) => (typeof v === "number" && Number.isFinite(v) ? Math.min(Math.max(v, 0), 1) : null);

function clean(mark) {
  if (!mark || typeof mark !== "object") return null;
  const color = COLORS.has(mark.color) ? mark.color : "red";
  if (mark.type === "ping") {
    const x = unit(mark.x), y = unit(mark.y);
    return x === null || y === null ? null : { type: "ping", x, y, color };
  }
  if (mark.type === "stroke" && Array.isArray(mark.points)) {
    const points = [];
    for (const p of mark.points.slice(0, MAX_POINTS)) {
      if (!Array.isArray(p) || p.length !== 2) continue;
      const x = unit(p[0]), y = unit(p[1]);
      if (x !== null && y !== null) points.push([x, y]);
    }
    return points.length >= 2 ? { type: "stroke", points, color } : null;
  }
  return null;
}

// Не больше max меток за скользящую секунду: лишние отбрасываются (окно меток не перегружается).
function createRate(max = MAX_PER_SECOND, now = () => Date.now()) {
  const times = [];
  return () => {
    const t = now();
    while (times.length && t - times[0] >= 1000) times.shift();
    if (times.length >= max) return false;
    times.push(t);
    return true;
  };
}

module.exports = { clean, createRate, MAX_POINTS, MAX_PER_SECOND, COLORS };
