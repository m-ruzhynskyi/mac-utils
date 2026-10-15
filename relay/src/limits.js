// Чистые функции и константы ограничений (см. .audit/auth-design.md, разделы 7 и 8).
// Без import и без обращения к окружению: файл склеивается с index.js/auth.js в тестах.
// Состояние (Map) принадлежит вызывающему и живёт в памяти Durable Object: после выгрузки оно теряется, это допустимо.

export const MAX_PENDING = 3;
export const AUTH_TIMEOUT_MS = 10_000;
export const DECLINE_BASE_MS = 60_000;
export const DECLINE_LONG_MS = 600_000;
export const CLAIM_PER_IP_PER_DAY = 5;

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
 * Лимит на IP применяется только если ip непустой.
 */
export function pendingAllowed(sockets, ip, maxPending, maxPerIp) {
  let total = 0;
  let same = 0;
  for (const socket of sockets) {
    if (socket && socket.readyState !== undefined && socket.readyState !== 1) continue;
    const info = socket && typeof socket.deserializeAttachment === "function" ? socket.deserializeAttachment() : socket;
    if (!info || info.approved !== false || info.ended) continue;
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
