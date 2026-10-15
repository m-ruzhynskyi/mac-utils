// Чистые функции и константы ограничений (см. .audit/auth-design.md, разделы 7 и 8).
// Без import и без обращения к окружению: файл склеивается с index.js/auth.js в тестах.
// Состояние (Map) принадлежит вызывающему и живёт в памяти Durable Object: после выгрузки оно теряется, это допустимо.

// Ожидающие ответа ведущего (legacy и v2 после проверки ключа): встреча из 10 человек и офис за одним NAT (B1).
export const MAX_PENDING = 10;
export const MAX_PENDING_PER_IP = 4;
// Подключения v2 до проверки ключа: честный клиент проходит её за RTT, поэтому лимит жёсткий.
// В комнате не больше MAX_UNAUTH (лишние вытесняют самого старого), с одного IP — MAX_UNAUTH_PER_IP.
// 5, а не 3: зрители встречи, нажавшие ссылку одновременно, не должны вытеснять друг друга за один RTT.
export const MAX_UNAUTH = 5;
export const MAX_UNAUTH_PER_IP = 1;
export const AUTH_TIMEOUT_MS = 10_000;
export const DECLINE_BASE_MS = 60_000;
export const DECLINE_LONG_MS = 600_000;
export const CLAIM_PER_IP_PER_DAY = 5;

/**
 * Ключ лимитов по адресу (M4): IPv4 — целиком, IPv6 — префикс /64 (у абонента их 2^64, ротация не должна давать новое окно).
 * IPv4-mapped IPv6 (::ffff:1.2.3.4) — как IPv4. Повторный вызов на результате возвращает его же.
 */
export function ipKey(ip) {
  if (typeof ip !== "string") return "";
  let s = ip.trim().toLowerCase();
  if (s === "") return "";
  if (!s.includes(":")) return s;
  if (s.endsWith("::/64")) return s;
  const zone = s.indexOf("%");
  if (zone >= 0) s = s.slice(0, zone);
  if (s.startsWith("[") && s.endsWith("]")) s = s.slice(1, -1);
  const mapped = s.match(/^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (mapped) return mapped[1];
  const halves = s.split("::");
  if (halves.length > 2) return s;
  const head = halves[0] ? halves[0].split(":") : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  // Хвост вида …:1.2.3.4 занимает две группы; для префикса /64 он не нужен, важна только длина.
  const count = (list) => list.reduce((n, g) => n + (g.includes(".") ? 2 : 1), 0);
  const fill = halves.length === 2 ? 8 - count(head) - count(tail) : 0;
  if (fill < 0 || (halves.length === 1 && count(head) !== 8)) return s;
  const groups = [...head, ...Array(fill).fill("0"), ...tail].slice(0, 4);
  if (groups.length < 4 || !groups.every((g) => /^[0-9a-f]{1,4}$/.test(g))) return s;
  return `${groups.map((g) => parseInt(g, 16).toString(16)).join(":")}::/64`;
}

/**
 * Окно фиксированной длины. Возвращает true, если обращение разрешено (и учтено),
 * false — если лимит окна исчерпан (отказ в счётчик не попадает).
 * map: Map<string, {start, count}>.
 */
export function windowHit(map, key, limit, periodMs, now) {
  if (map.size > 1000) {
    for (const [k, v] of map) if (now - v.start >= periodMs) map.delete(k);
  }
  const entry = map.get(key);
  if (!entry || now - entry.start >= periodMs || now < entry.start) {
    if (limit < 1) return false;
    map.set(key, { start: now, count: 1 });
    return true;
  }
  if (entry.count >= limit) return false;
  entry.count += 1;
  return true;
}

/**
 * Можно ли принять ещё один не одобренный запрос (pending).
 * sockets — сокеты комнаты (с deserializeAttachment()) или готовые объекты вложений.
 * Pending = вложение с approved === false, не ended. IP берётся из info.ip.
 * Лимит на IP применяется только если ip непустой. filter(info) — какие из pending считать (по умолчанию все).
 */
export function pendingAllowed(sockets, ip, maxPending, maxPerIp, filter = null) {
  let total = 0;
  let same = 0;
  for (const socket of sockets) {
    if (socket && socket.readyState !== undefined && socket.readyState !== 1) continue;
    const info = socket && typeof socket.deserializeAttachment === "function" ? socket.deserializeAttachment() : socket;
    if (!info || info.approved !== false || info.ended) continue;
    if (filter && !filter(info)) continue;
    total += 1;
    if (ip && info.ip === ip) same += 1;
  }
  if (total >= maxPending) return false;
  if (ip && same >= maxPerIp) return false;
  return true;
}

/** Сколько миллисекунд ещё действует пауза после отказа (0 — паузы нет). map: Map<string, {until, streak, last}>. */
export function declineCooldown(map, key, now) {
  const entry = map.get(key);
  if (!entry) return 0;
  return entry.until > now ? entry.until - now : 0;
}

/**
 * Записать отказ хоста. Первые два подряд — пауза DECLINE_BASE_MS, третий и далее — DECLINE_LONG_MS.
 * Серия сбрасывается, если после окончания паузы прошло больше DECLINE_LONG_MS без отказов.
 */
export function noteDecline(map, key, now) {
  const prev = map.get(key);
  const fresh = !prev || now - prev.until > DECLINE_LONG_MS;
  const streak = fresh ? 1 : prev.streak + 1;
  map.set(key, { until: now + (streak >= 3 ? DECLINE_LONG_MS : DECLINE_BASE_MS), streak, last: now });
  if (map.size > 1000) {
    for (const [k, v] of map) if (now - v.until > DECLINE_LONG_MS) map.delete(k);
  }
}
