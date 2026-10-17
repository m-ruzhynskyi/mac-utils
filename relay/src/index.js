// Ретранслятор трансляции экрана Mac Utils (по принципу AnyDesk).
// У каждого пользователя постоянный 10-значный ID — это и есть его «комната».
// Ведущий: /room/<ID>?role=host. Зритель: /room/<ID>?role=viewer&viewer=<свой ID>&name=<имя компьютера>.
// Зритель ждёт, пока ведущий его пустит: ведущему приходит {"type":"request"}, он отвечает
// {"type":"accept"|"decline","viewer":"…","name":"<имя ведущего>"}. Кадры и звук идут только пущенным зрителям.
// Двоичные сообщения: первый байт — тип (1 — кадр JPEG, 2 — звук PCM 16 бит, 24 кГц, моно).
// Текст от пущенных зрителей (метки {"type":"ping"|"stroke"}) — ведущему и остальным зрителям.
// /status?ids=a,b,c — кто из них сейчас в эфире (для отметок в истории); POST /status — то же с подписью.
// /version — коммит, принимаемые протоколы и режим проверки ключей.
// Протокол mu-share-2: устройство доказывает владение ключом Ed25519 или P-256 (challenge/response, см. auth.js),
// ID привязывается к ключу в хранилище комнаты. mu-share-1 (без ключей) работает по-старому, пока AUTH_MODE != required.
// Клиент с заголовком mu-share-1, у страницы которого есть свой ключ (WebCrypto), просит проверку параметром `auth=v2`.
// Кадры и звук сервер не разбирает — только пересылает.

import page from "./index.html";
import landing from "./landing.html";
// Одной строкой каждый: тестовая обвязка вырезает import и склеивает файлы в один скрипт.
import { MAX_PENDING, MAX_PENDING_PER_IP, MAX_UNAUTH, MAX_UNAUTH_PER_IP, MAX_UNAUTH_VIEWERS_PER_IP, AUTH_TIMEOUT_MS, CLAIM_PER_IP_PER_DAY, ipKey, windowHit, pendingAllowed, declineCooldown, noteDecline } from "./limits.js";
import { b64uHasLength, isPublicKey, hostMessage, viewerMessage, statusMessage, verifyEd25519, verifyDevice, fingerprintOf, newNonce } from "./auth.js";

// Смотреть и транслировать можно только из приложений Mac Utils (Mac) и Mac Utils Share (Windows):
// они добавляют этот заголовок к каждому запросу. В обычном браузере — страница со ссылками на приложения.
const CLIENT_HEADER = "x-macutils-client";
const CLIENT_V1 = "mu-share-1";
const CLIENT_V2 = "mu-share-2";
const ACCEPTED_CLIENTS = new Set([CLIENT_V1, CLIENT_V2]);
const MAX_VIEWERS = 10;
const HOST_TIMEOUT_MS = 120_000;
// Связь с ведущим оборвалась не по «Стоп» — ждём, пока он переподключится, зрители не отключаются.
const HOST_GRACE_MS = 45_000;
const HOST_CHECK_MS = 30_000;
const VIEWER_TIMEOUT_MS = 120_000;
const ID = /^\d{6}$|^\d{10}$/;
const ID10 = /^\d{10}$/;
const OWNER_TTL_MS = 180 * 86_400_000;
const OWNER_TOUCH_MS = 3_600_000;
const STATUS_MAX_IDS = 20;
const STATUS_SKEW_MS = 120_000;
const STATUS_PER_KEY_PER_MIN = 6;
// Встреча из 10–20 человек не должна ждать минуту, пока ведущий увидит запрос (B1).
const REQUESTS_PER_MIN = 20;
const CLAIM_PERIOD_MS = 86_400_000;
// Лимит /status по ключу — в памяти изолята Worker (приблизительный: изолятов может быть несколько).
const statusWindow = new Map();

const ERRORS = {
  "bad-signature": [4401, "Не удалось подтвердить устройство"],
  "id-format": [4400, "Этот ID не подходит для проверки устройства"],
  "id-claimed": [4403, "Этот ID занят другим устройством"],
  "auth-timeout": [4408, "Время проверки устройства истекло"],
  "replaced": [4409, "Подключилось другое окно этого компьютера"],
  "rate-limited": [4429, "Слишком много запросов, попробуйте позже"],
};

const MARK_COLORS = new Set(["red", "yellow", "green", "blue", "white"]);
const MAX_STROKE_POINTS = 2000;
const unit = (value) => (typeof value === "number" && Number.isFinite(value) ? Math.min(Math.max(value, 0), 1) : null);

// Метка зрителя: пересобирается из проверенных полей, остальное отбрасывается.
function sanitizeMark(command) {
  if (!command || typeof command !== "object") return null;
  const color = MARK_COLORS.has(command.color) ? command.color : "red";
  if (command.type === "ping") {
    const x = unit(command.x), y = unit(command.y);
    return x === null || y === null ? null : { type: "ping", x, y, color };
  }
  if (command.type === "stroke") {
    if (!Array.isArray(command.points)) return null;
    const points = [];
    for (const point of command.points.slice(0, MAX_STROKE_POINTS)) {
      if (!Array.isArray(point) || point.length !== 2) continue;
      const x = unit(point[0]), y = unit(point[1]);
      if (x !== null && y !== null) points.push([x, y]);
    }
    return points.length >= 2 ? { type: "stroke", points, color } : null;
  }
  return null;
}

const GAME_ACTIONS = new Set(["invite", "accept", "decline", "move", "again", "quit"]);
const MAX_ROUND = 1_000_000;

// Сообщение игры от зрителя: только известные поля с проверенными значениями.
function sanitizeGame(command) {
  if (!command || typeof command !== "object" || !GAME_ACTIONS.has(command.action)) return null;
  const game = { type: "game", action: command.action };
  // Поле есть, но значение негодное — сообщение отбрасывается целиком; нет поля — хост сам решит.
  if (command.cell !== undefined) {
    if (!Number.isInteger(command.cell) || command.cell < 0 || command.cell > 8) return null;
    game.cell = command.cell;
  }
  if (command.round !== undefined) {
    if (!Number.isInteger(command.round) || command.round < 0 || command.round > MAX_ROUND) return null;
    game.round = command.round;
  }
  if (typeof command.busy === "boolean") game.busy = command.busy;
  return game;
}

// Token bucket на сокет зрителя: RATE сообщений/с, всплеск BURST.
const RATE_PER_SECOND = 20;
const RATE_BURST = 40;
const buckets = new WeakMap();
function takeToken(socket, now = Date.now()) {
  const bucket = buckets.get(socket) || { tokens: RATE_BURST, at: now };
  bucket.tokens = Math.min(RATE_BURST, bucket.tokens + ((now - bucket.at) / 1000) * RATE_PER_SECOND);
  bucket.at = now;
  buckets.set(socket, bucket);
  if (bucket.tokens < 1) return false;
  bucket.tokens -= 1;
  return true;
}

function clientToken(request) {
  const token = request.headers.get(CLIENT_HEADER);
  return ACCEPTED_CLIENTS.has(token) ? token : null;
}

function isClient(request) {
  return clientToken(request) !== null;
}

// Клиент проходит проверку ключом: заголовок mu-share-2 (приложение с ключом) или mu-share-1 и `auth=v2` — страница
// сама создала ключ (WebCrypto), а приложение заголовок не меняет (клиент для Windows). Старый relay параметр не знает.
function keyedClient(token, url) {
  return token === CLIENT_V2 || (token === CLIENT_V1 && url.searchParams.get("auth") === "v2");
}

// off — ключи игнорируются (аварийный откат); required — только mu-share-2; иначе optional.
function authMode(env) {
  const mode = env && env.AUTH_MODE;
  return mode === "off" || mode === "required" ? mode : "optional";
}

async function limited(binding, ip) {
  if (!binding || !ip) return false;
  try { return !(await binding.limit({ key: ip })).success; } catch (_) { return false; }
}

async function liveStatus(env, ids) {
  const result = {};
  const revisions = new Set();
  await Promise.all(ids.map(async (id) => {
    const response = await env.ROOMS.get(env.ROOMS.idFromName(id)).fetch("https://room/live");
    revisions.add(response.headers.get("x-relay-revision") || "legacy");
    result[id] = (await response.text()) === "1";
  }));
  return Response.json(result, { headers: { "cache-control": "no-store", "x-relay-room-revision": [...revisions].join(",") } });
}

const jsonError = (error, status) => Response.json({ error }, { status, headers: { "cache-control": "no-store" } });

// POST /status: подписанный запрос (хозяин ID спрашивает про список ID), строка подписи — statusMessage.
async function statusPost(request, env, ip) {
  if (await limited(env.RL_STATUS, ip)) return jsonError("rate-limited", 429);
  let body;
  try {
    const text = await request.text();
    if (text.length > 4096) return jsonError("too-large", 413);
    body = JSON.parse(text);
  } catch (_) { return jsonError("bad-request", 400); }
  const now = Date.now();
  const ok = body && typeof body === "object" && body.v === 2 && typeof body.id === "string" && ID10.test(body.id) &&
    typeof body.pub === "string" && b64uHasLength(body.pub, 32) && typeof body.sig === "string" &&
    Number.isSafeInteger(body.ts) && Math.abs(now - body.ts) <= STATUS_SKEW_MS &&
    Array.isArray(body.ids) && body.ids.length <= STATUS_MAX_IDS && body.ids.every((id) => typeof id === "string" && ID10.test(id));
  if (!ok) return jsonError("bad-request", 400);
  // Сначала подпись, потом окно по ключу: иначе чужие подделки с публичным ключом владельца съедают его лимит (N1).
  if (!(await verifyEd25519(body.pub, body.sig, statusMessage(body.id, body.ts, body.ids)))) return jsonError("bad-signature", 401);
  const fp = await fingerprintOf(body.pub);
  if (!windowHit(statusWindow, fp, STATUS_PER_KEY_PER_MIN, 60_000, now)) return jsonError("rate-limited", 429);
  // Ключ должен уже принадлежать этому ID. Только чтение: /status никогда не привязывает свободный ID.
  let owner;
  try {
    const response = await env.ROOMS.get(env.ROOMS.idFromName(body.id)).fetch("https://room/owner", { method: "POST" });
    owner = await response.json();
  } catch (_) { return jsonError("unavailable", 503); }
  if (!owner || typeof owner !== "object") return jsonError("unavailable", 503);
  if (owner.pub !== body.pub) return jsonError(owner.pub ? "id-claimed" : "not-owner", 403);
  return liveStatus(env, [...new Set(body.ids)]);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const mode = authMode(env);
    const token = clientToken(request);
    // Все лимиты по IP — по ipKey: IPv4 целиком, IPv6 по /64 (M4).
    const ip = ipKey(request.headers.get("CF-Connecting-IP") || "");
    if (url.pathname === "/version") {
      const protocols = mode === "required" ? [CLIENT_V2] : [...ACCEPTED_CLIENTS];
      return Response.json({ commit: env.RELAY_COMMIT ?? "dev", protocols, auth: mode }, { headers: { "cache-control": "no-store" } });
    }
    const room = url.pathname.match(/^\/room\/(\d+)$/);
    if (url.pathname === "/status") {
      if (!token) return new Response("Use the Mac Utils app", { status: 403 });
      if (request.method === "POST") {
        if (mode === "off") return new Response("Not found", { status: 404 });
        if (mode === "required" && token !== CLIENT_V2) return new Response("Update Mac Utils", { status: 426 });
        return statusPost(request, env, ip);
      }
      if (mode === "required") return new Response("Update Mac Utils", { status: 426 });
      if (await limited(env.RL_STATUS, ip)) return new Response("Too many requests", { status: 429 });
      const ids = (url.searchParams.get("ids") || "").split(",").filter((id) => ID10.test(id)).slice(0, STATUS_MAX_IDS);
      return liveStatus(env, ids);
    }
    // GET /room/<ID>/host-check: страница узнаёт причину отказа ведущему без WebSocket. Лимит тот же, что у подключений.
    const check = url.pathname.match(/^\/room\/(\d+)\/host-check$/);
    if (check && ID.test(check[1])) {
      if (request.method !== "GET") return new Response("Method not allowed", { status: 405 });
      if (!token) return new Response("Use the Mac Utils app", { status: 403 });
      if (mode === "required" && !keyedClient(token, url)) return new Response("Update Mac Utils", { status: 426 });
      if (await limited(env.RL_CONNECT, ip)) return jsonError("rate-limited", 429);
      const headers = new Headers(request.headers);
      headers.set("x-relay-ip", ip);
      return env.ROOMS.get(env.ROOMS.idFromName(check[1])).fetch(new Request(request, { headers }));
    }
    if (!room || !ID.test(room[1])) {
      return new Response(isClient(request) ? page : landing, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }
    if (!token) return new Response("Use the Mac Utils app", { status: 403 });
    if (mode === "required" && !keyedClient(token, url)) return new Response("Update Mac Utils", { status: 426 });
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }
    if (await limited(env.RL_CONNECT, ip)) return new Response("Too many connections", { status: 429 });
    // IP кладём сами (уже как ipKey) и всегда перезаписываем: клиентский заголовок с таким именем не доходит до комнаты.
    const headers = new Headers(request.headers);
    headers.set("x-relay-ip", ip);
    return env.ROOMS.get(env.ROOMS.idFromName(room[1])).fetch(new Request(request, { headers }));
  },
};

export class Room {
  constructor(state, env) {
    this.state = state;
    this.env = env || {};
    // В памяти: после выгрузки объекта обнуляются, это допустимо (.audit/auth-design.md §7).
    this.declines = new Map();
    this.requestWindow = new Map();
    // Цепочка для операций «прочитать — сравнить — записать» в storage (владелец ID, квота привязок).
    this.chain = Promise.resolve();
  }

  async fetch(request) {
    const url = new URL(request.url);
    // Внутренние вызовы между комнатами. Снаружи недоступны: Worker пропускает к комнате только /room/<цифры>.
    if (request.method === "POST" && url.pathname === "/claim") return this.claimRoute(request);
    if (request.method === "POST" && url.pathname === "/quota") return this.quotaRoute(request);
    if (request.method === "POST" && url.pathname === "/owner") return this.ownerRoute();
    this.expireViewers();
    this.flushRequests();
    const hosts = this.activeHosts();
    if (hosts.length) await this.ensureAlarm();
    if (url.pathname === "/live") return new Response(hosts.length > 0 ? "1" : "0", { headers: { "x-relay-revision": "auth-v2-1" } });
    if (request.method === "GET" && /^\/room\/\d+\/host-check$/.test(url.pathname)) return this.hostCheck(hosts.length > 0, keyedClient(clientToken(request), url) && authMode(this.env) !== "off", authMode(this.env));

    const mode = authMode(this.env);
    const token = clientToken(request);
    if (mode === "required" && !keyedClient(token, url)) return new Response("Update Mac Utils", { status: 426 });
    const v2 = keyedClient(token, url) && mode !== "off";
    const roomId = (url.pathname.match(/^\/room\/(\d+)$/) || [])[1] || "";
    const ip = ipKey(request.headers.get("x-relay-ip") || "");
    const role = url.searchParams.get("role");

    if (role === "host") {
      if (v2) return this.connectHostV2(roomId, ip);
      if (hosts.length > 0) return new Response("Room is busy", { status: 409 });
      // Старый хост без ключа не может занять ID, который уже привязан к устройству.
      if (mode !== "off" && await this.readOwner()) return new Response("id-claimed", { status: 409 });
    } else {
      if (hosts.length === 0) return new Response("No broadcast with this ID", { status: 404 });
      if (this.approvedViewers().length >= MAX_VIEWERS) {
        return new Response("Too many viewers", { status: 429 });
      }
      // Ожидающие ответа ведущего: 10 в комнате, 4 с IP (офис за NAT, встреча) — и для legacy, и для v2 после ключа.
      if (!this.waitingAllowed(ip)) return new Response("rate-limited", { status: 429 });
      if (v2) {
        // До проверки ключа: с одного IP — 3 (F3); комната полна — вытесняется самый старый, проверяемые последними (M1, F2).
        const room = { perIp: MAX_UNAUTH_VIEWERS_PER_IP, sameIpCode: "rate-limited", strictSameIp: true };
        if (!this.makeRoomForUnauth(this.unauthViewers(), ip, room)) return new Response("rate-limited", { status: 429 });
      } else if (ip && declineCooldown(this.declines, `ip:${ip}`, Date.now()) > 0) {
        return new Response("rate-limited", { status: 429 });
      }
    }
    const [client, server] = Object.values(new WebSocketPair());
    if (role === "host") {
      this.state.acceptWebSocket(server, ["host"]);
      server.serializeAttachment({ lastSeen: Date.now() });
      if (token === CLIENT_V2) server.send(JSON.stringify({ type: "authed", v: 2, mode: "off" }));
      await this.resumeViewers();
      await this.ensureAlarm();
    } else if (v2) {
      return this.connectViewerV2(url, roomId, ip, server, client);
    } else {
      let viewer = (url.searchParams.get("viewer") || "").replace(/\D/g, "").slice(0, 10);
      // ID комнаты как ID зрителя — подделка (его знает любой, у кого есть код): старые Mac-хосты 1.3.x
      // принимали такого «себя» без вопроса. Отдаём хосту пустой ID, он покажет обычный запрос.
      if (viewer === roomId) viewer = "";
      const name = (url.searchParams.get("name") || "Без имени").slice(0, 60);
      this.state.acceptWebSocket(server, ["viewer"]);
      // h264=1 — зритель понимает видео H.264; старые версии понимают только кадры JPEG.
      const h264 = url.searchParams.get("h264") === "1";
      const rid = crypto.randomUUID();
      server.serializeAttachment({ id: viewer, name, h264, rid, approved: false, lastSeen: Date.now(), auth: "none", ip, reqSent: false });
      server.send(JSON.stringify({ type: "waiting" }));
      await this.requestOrQueue(server);
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  // ---- Владелец ID (ключ в хранилище комнаты) ----

  // Те же отказы, что у host-подключения без ключа (mu-share-1): занято окном — busy, ID привязан к ключу — id-claimed.
  // С mu-share-2 привязанный ID не отказ: ведущий докажет владение ключом.
  async hostCheck(busy, v2, mode) {
    const headers = { "cache-control": "no-store" };
    if (busy && !v2) return Response.json({ error: "busy" }, { headers });
    if (!v2 && mode !== "off" && await this.readOwner()) return Response.json({ error: "id-claimed" }, { headers });
    return Response.json({ ok: true }, { headers });
  }

  async readOwner() {
    const owner = await this.state.storage.get("owner");
    if (!owner || owner.v !== 2 || typeof owner.pub !== "string") return null;
    // Ключ потерян и восстановить его нельзя: ID свободен, если владелец не появлялся 180 дней.
    if (Date.now() - (owner.lastSeenAt ?? 0) > OWNER_TTL_MS) return null;
    return owner;
  }

  serial(run) {
    const result = this.chain.then(run, run);
    this.chain = result.catch(() => {});
    return result;
  }

  // Запись владельца и сравнение — одним потоком, без гонки двух подключений.
  // useQuota: только привязка ID зрителя (вызов /claim из чужой комнаты) тратит суточную квоту IP; хост — нет (F1).
  claimOwner(pub, ip, useQuota) {
    return this.serial(() => this.claimOwnerNow(pub, ip, useQuota));
  }

  async claimOwnerNow(pub, ip, useQuota) {
    const now = Date.now();
    const owner = await this.readOwner();
    if (owner) {
      if (owner.pub !== pub) return { ok: false, reason: "id-claimed" };
      if (now - owner.lastSeenAt >= OWNER_TOUCH_MS) await this.state.storage.put("owner", { ...owner, lastSeenAt: now });
      return { ok: true, claimed: false };
    }
    if (useQuota && ip && !(await this.takeClaimQuota(ip))) return { ok: false, reason: "rate-limited" };
    const fp = await fingerprintOf(pub);
    await this.state.storage.put("owner", { v: 2, pub, fp, claimedAt: now, lastSeenAt: now });
    return { ok: true, claimed: true };
  }

  // Счётчик новых привязок по IP за сутки — в storage отдельной комнаты «__limits» (M3): переживает выгрузку объекта.
  // Сбой счётчика — отказ (fail-closed): у зрителя это лишь idVerified:false.
  async takeClaimQuota(ip) {
    if (!this.env.ROOMS) return false;
    try {
      const response = await this.env.ROOMS.get(this.env.ROOMS.idFromName("__limits")).fetch("https://room/quota", {
        method: "POST", body: JSON.stringify({ key: ip }),
      });
      const result = await response.json();
      return result && result.ok === true;
    } catch (_) { return false; }
  }

  async quotaRoute(request) {
    let key = "";
    try { key = ipKey(String((await request.json()).key ?? "")); } catch (_) {}
    if (key === "") return Response.json({ ok: false });
    return this.serial(async () => {
      const now = Date.now(), name = `q:${key}`;
      const entry = await this.state.storage.get(name);
      let ok = true;
      if (!entry || now - entry.start >= CLAIM_PERIOD_MS || now < entry.start) await this.state.storage.put(name, { start: now, count: 1 });
      else if (entry.count >= CLAIM_PER_IP_PER_DAY) ok = false;
      else await this.state.storage.put(name, { start: entry.start, count: entry.count + 1 });
      await this.pruneQuota(now);
      return Response.json({ ok });
    });
  }

  // Старые счётчики стираются не чаще раза в час (просроченные сутки).
  async pruneQuota(now) {
    if (typeof this.state.storage.list !== "function" || now - (this.prunedAt ?? -Infinity) < 3_600_000) return;
    this.prunedAt = now;
    const entries = await this.state.storage.list({ prefix: "q:", limit: 1000 });
    const stale = [...entries].filter(([, value]) => !value || now - value.start >= CLAIM_PERIOD_MS).map(([key]) => key);
    if (stale.length) await this.state.storage.delete(stale);
  }

  // Привязка ID зрителя к ключу (вызов из другой комнаты). Квота строгая: сбой счётчика = отказ (idVerified:false безвреден).
  async claimRoute(request) {
    let body;
    try { body = await request.json(); } catch (_) { return Response.json({ ok: false, reason: "bad-request" }, { status: 400 }); }
    if (!body || typeof body.pub !== "string" || !isPublicKey(body.pub)) {
      return Response.json({ ok: false, reason: "bad-request" }, { status: 400 });
    }
    const result = await this.claimOwner(body.pub, ipKey(typeof body.ip === "string" ? body.ip : ""), true);
    return Response.json({ ok: result.ok, claimed: !!result.claimed, reason: result.reason });
  }

  // Владелец ID без привязки и без записи (для POST /status).
  async ownerRoute() {
    const owner = await this.readOwner();
    return Response.json({ pub: owner ? owner.pub : null });
  }

  // ---- Подключение v2 ----

  pendingHosts() {
    return this.state.getWebSockets("host").filter((s) => {
      const info = s.deserializeAttachment() || {};
      return s.readyState === 1 && !info.ended && info.auth === "pending";
    });
  }

  unauthViewers() {
    return this.state.getWebSockets("viewer").filter((s) => {
      const info = s.deserializeAttachment() || {};
      return s.readyState === 1 && !info.ended && info.auth === "pending";
    });
  }

  waitingAllowed(ip) {
    return pendingAllowed(this.state.getWebSockets("viewer"), ip, MAX_PENDING, MAX_PENDING_PER_IP, (info) => info.auth !== "pending");
  }

  // Место для ещё одного сокета до проверки ключа (M1). Неаутентифицированный сокет ничего не держит:
  // при переполнении комнаты уходит самый старый, а не отказ новому (иначе молчащие сокеты держат комнату).
  // Порядок вытеснения: сначала не приславшие auth, приславшие (verifying, идёт проверка) — последними (F2).
  // С одного IP — perIp. Лишние с этого IP вытесняются (sameIpCode); если вытеснять пришлось бы
  // уже проверяемый сокет, а strictSameIp — новый получает отказ (зритель), хост вытесняет всё равно.
  makeRoomForUnauth(sockets, ip, { perIp, sameIpCode, strictSameIp }) {
    const info = (socket) => socket.deserializeAttachment() || {};
    const order = (x, y) => (info(x).verifying ? 1 : 0) - (info(y).verifying ? 1 : 0) || (info(x).connectedAt ?? 0) - (info(y).connectedAt ?? 0);
    const live = () => sockets.filter((socket) => !info(socket).ended).sort(order);
    if (ip) {
      const same = live().filter((socket) => info(socket).ip === ip);
      const victims = same.slice(0, Math.max(0, same.length - perIp + 1));
      if (strictSameIp && victims.some((socket) => info(socket).verifying)) return false;
      for (const old of victims) this.failAuth(old, sameIpCode);
    }
    const rest = live();
    for (const old of rest.slice(0, Math.max(0, rest.length - MAX_UNAUTH + 1))) this.failAuth(old, "rate-limited");
    return true;
  }

  async connectHostV2(roomId, ip) {
    this.makeRoomForUnauth(this.pendingHosts(), ip, { perIp: MAX_UNAUTH_PER_IP, sameIpCode: "replaced", strictSameIp: false });
    const [client, server] = Object.values(new WebSocketPair());
    const nonce = newNonce(), now = Date.now();
    this.state.acceptWebSocket(server, ["host"]);
    server.serializeAttachment({ auth: "pending", nonce, roomId, ip, connectedAt: now, lastSeen: now });
    server.send(JSON.stringify({ type: "challenge", v: 2, nonce }));
    await this.armAlarmAt(now + AUTH_TIMEOUT_MS + 250);
    return new Response(null, { status: 101, webSocket: client });
  }

  async connectViewerV2(url, roomId, ip, server, client) {
    const rawId = url.searchParams.get("viewer") || "";
    const name = (url.searchParams.get("name") || "Без имени").slice(0, 60);
    const h264 = url.searchParams.get("h264") === "1";
    const rid = crypto.randomUUID(), nonce = newNonce(), now = Date.now();
    this.state.acceptWebSocket(server, ["viewer"]);
    if (!ID10.test(rawId)) {
      // Подпись считается по ID ровно как он пришёл, поэтому никакой нормализации: только 10 цифр.
      server.serializeAttachment({ id: "", name, approved: false, auth: "pending", ended: true, lastSeen: now });
      this.sendError(server, "id-format");
      try { server.close(...this.closeArgs("id-format")); } catch (_) {}
      return new Response(null, { status: 101, webSocket: client });
    }
    const owner = await this.readOwner();
    server.serializeAttachment({ id: rawId, name, h264, rid, approved: false, auth: "pending", nonce, roomId, ip, connectedAt: now, lastSeen: now, reqSent: false });
    server.send(JSON.stringify({ type: "challenge", v: 2, nonce, rid, hostKey: owner ? owner.pub : null, hostFp: owner ? owner.fp : null }));
    await this.armAlarmAt(now + AUTH_TIMEOUT_MS + 250);
    return new Response(null, { status: 101, webSocket: client });
  }

  closeArgs(code) { return [ERRORS[code][0], code]; }

  sendError(socket, code) {
    try { socket.send(JSON.stringify({ type: "error", code, message: ERRORS[code][1] })); } catch (_) {}
  }

  // Ошибка проверки: сокет помечается завершённым (без «обрыва ведущего» и без cancelled), клиенту — код и закрытие.
  failAuth(socket, code) {
    const info = socket.deserializeAttachment() || {};
    socket.serializeAttachment({ ...info, ended: true });
    this.sendError(socket, code);
    try { socket.close(...this.closeArgs(code)); } catch (_) {}
  }

  // Подпись, привязка и т.п. занимают время: за это время сокет мог закрыться или быть завершён.
  stillPending(socket) {
    const info = socket.deserializeAttachment();
    return info && !info.ended && info.auth === "pending" && socket.readyState === 1 ? info : null;
  }

  // Ed25519 (32 байта) или P-256 (несжатая точка, 65 байт); подпись — 64 байта в обоих случаях.
  parseAuth(command) {
    if (!command || command.type !== "auth" || command.v !== 2) return null;
    const keyBytes = command.alg === "ed25519" ? 32 : command.alg === "es256" ? 65 : 0;
    if (!keyBytes || typeof command.pub !== "string" || typeof command.sig !== "string") return null;
    if (!b64uHasLength(command.pub, keyBytes) || !isPublicKey(command.pub) || !b64uHasLength(command.sig, 64)) return null;
    return { alg: command.alg, pub: command.pub, sig: command.sig };
  }

  // Сокет прислал auth: идёт проверка подписи и привязки (до сотен мс). Такие вытесняются последними (F2).
  markVerifying(socket, info) {
    if (!info.verifying) socket.serializeAttachment({ ...info, verifying: true });
    return { ...info, verifying: true };
  }

  async handleHostAuth(socket, command) {
    const pending = this.stillPending(socket);
    if (!pending) return;
    const info = this.markVerifying(socket, pending);
    const auth = this.parseAuth(command);
    if (!auth || !(await verifyDevice(auth.alg, auth.pub, auth.sig, hostMessage(info.roomId, info.nonce)))) {
      return this.failAuth(socket, "bad-signature");
    }
    // 6-значные ID перебираются за ~10^6 запросов: привязывать ключ к ним нельзя.
    if (!ID10.test(info.roomId)) return this.failAuth(socket, "id-format");
    const claim = await this.claimOwner(auth.pub, info.ip, false);
    if (!claim.ok) return this.failAuth(socket, claim.reason === "rate-limited" ? "rate-limited" : "id-claimed");
    const fp = await fingerprintOf(auth.pub);
    const current = this.stillPending(socket);
    if (!current) return;
    // Владелец вернулся: прежние подключения хоста (старое окно того же устройства или самозванец без ключа) уступают.
    let foreign = false;
    for (const other of this.activeHosts()) {
      if (other === socket) continue;
      const otherInfo = other.deserializeAttachment() || {};
      if (otherInfo.auth !== "key") foreign = true;
      other.serializeAttachment({ ...otherInfo, ended: true });
      if (otherInfo.auth === "key") this.sendError(other, "replaced");
      try { other.close(...this.closeArgs("replaced")); } catch (_) {}
    }
    // Зрителей, которых пустил хост без проверенного ключа, владельцу не передаём.
    if (foreign) this.endViewers();
    // M2: пущенные зрители остаются только у того ключа, который их пустил, — и в grace, когда прежнего хоста уже нет.
    for (const viewer of this.approvedViewers()) {
      if ((viewer.deserializeAttachment() || {}).approvedBy !== auth.pub) this.endViewer(viewer);
    }
    socket.serializeAttachment({ ...current, auth: "key", pub: auth.pub, fp, nonce: undefined, verifying: undefined, lastSeen: Date.now() });
    socket.send(JSON.stringify({ type: "authed", v: 2, fp, claimed: claim.claimed }));
    await this.resumeViewers();
    await this.ensureAlarm();
  }

  async resumeViewers() {
    if (this.hostLostAt ?? (await this.state.storage.get("hostLostAt"))) {
      this.hostLostAt = null;
      await this.state.storage.delete("hostLostAt");
      for (const viewer of this.activeViewers()) {
        try { viewer.send(JSON.stringify({ type: "resumed" })); } catch (_) {}
      }
    }
  }

  async verifyViewerId(id, pub, ip) {
    if (!this.env.ROOMS) return false;
    try {
      const response = await this.env.ROOMS.get(this.env.ROOMS.idFromName(id)).fetch("https://room/claim", {
        method: "POST", body: JSON.stringify({ pub, ip }),
      });
      return (await response.json()).ok === true;
    } catch (_) { return false; }
  }

  async handleViewerAuth(socket, command) {
    const pending = this.stillPending(socket);
    if (!pending) return;
    const info = this.markVerifying(socket, pending);
    const auth = this.parseAuth(command);
    if (!auth || !(await verifyDevice(auth.alg, auth.pub, auth.sig, viewerMessage(info.roomId, info.id, info.rid, info.nonce)))) {
      return this.failAuth(socket, "bad-signature");
    }
    const owner = await this.readOwner();
    const self = !!owner && owner.pub === auth.pub;
    // Пауза после отказа — до привязки ID: отклонённый не тратит квоту и не закрепляет новый ID.
    if (!self && declineCooldown(this.declines, `k:${auth.pub}`, Date.now()) > 0) return this.failAuth(socket, "rate-limited");
    const fp = await fingerprintOf(auth.pub);
    let id = info.id, idVerified;
    if (info.id === info.roomId) {
      // ID комнаты как свой ID годится только владельцу комнаты (подпись требует его приватного ключа).
      idVerified = self;
      if (!self) id = "";
    } else {
      idVerified = await this.verifyViewerId(info.id, auth.pub, info.ip);
    }
    const current = this.stillPending(socket);
    if (!current) return;
    if (!self && !this.waitingAllowed(current.ip)) return this.failAuth(socket, "rate-limited");
    socket.serializeAttachment({ ...current, auth: "key", pub: auth.pub, fp, idVerified, self, id, nonce: undefined, verifying: undefined, lastSeen: Date.now() });
    socket.send(JSON.stringify({ type: "waiting", v: 2, rid: current.rid }));
    await this.requestOrQueue(socket);
  }

  // ---- Запросы хосту: не больше REQUESTS_PER_MIN в минуту, остальные ждут своей очереди ----

  requestMessage(info, hostAuth) {
    const base = { type: "request", viewer: info.id, name: info.name, rid: info.rid };
    if (info.auth === "key") {
      return { ...base, v: 2, auth: "key", pub: info.pub, fp: info.fp, idVerified: !!info.idVerified, self: !!info.self };
    }
    // Хосту v2 нужно знать, что у зрителя нет ключа; старые хосты получают сообщение как раньше.
    return hostAuth === "key" ? { ...base, v: 2, auth: "none" } : base;
  }

  tryRequest(socket) {
    const info = socket.deserializeAttachment();
    if (!info || info.ended) return true;
    if (!info.self && !windowHit(this.requestWindow, "request", REQUESTS_PER_MIN, 60_000, Date.now())) return false;
    for (const host of this.activeHosts()) {
      const hostInfo = host.deserializeAttachment() || {};
      try { host.send(JSON.stringify(this.requestMessage(info, hostInfo.auth))); } catch (_) {}
    }
    socket.serializeAttachment({ ...info, reqSent: true });
    return true;
  }

  async requestOrQueue(socket) {
    if (this.tryRequest(socket)) return;
    await this.armAlarmAt(this.nextRequestSlot());
  }

  nextRequestSlot() {
    const entry = this.requestWindow.get("request");
    return (entry ? entry.start : Date.now()) + 60_000 + 250;
  }

  queuedViewers() {
    return this.activeViewers().filter((s) => {
      const info = s.deserializeAttachment() || {};
      return info.reqSent === false && info.auth !== "pending" && !info.approved;
    });
  }

  flushRequests() {
    for (const socket of this.queuedViewers()) {
      if (!this.tryRequest(socket)) break;
    }
  }

  // ---- Будильник: проверка таймаута, очередь запросов ----

  async armAlarmAt(ts) {
    const current = await this.state.storage.getAlarm();
    if (current == null || current > ts || current <= Date.now()) await this.state.storage.setAlarm(ts);
  }

  unauthenticated() {
    return [...this.state.getWebSockets("host"), ...this.state.getWebSockets("viewer")].filter((s) => {
      const info = s.deserializeAttachment() || {};
      return info.auth === "pending" && !info.ended && s.readyState === 1;
    });
  }

  reapUnauthenticated() {
    const now = Date.now();
    for (const socket of this.unauthenticated()) {
      const info = socket.deserializeAttachment() || {};
      if (now - (info.connectedAt ?? now) >= AUTH_TIMEOUT_MS) this.failAuth(socket, "auth-timeout");
    }
  }

  async rearm() {
    let next = Infinity;
    for (const socket of this.unauthenticated()) {
      const info = socket.deserializeAttachment() || {};
      next = Math.min(next, (info.connectedAt ?? Date.now()) + AUTH_TIMEOUT_MS + 250);
    }
    if (this.queuedViewers().length) next = Math.min(next, this.nextRequestSlot());
    if (next !== Infinity) await this.armAlarmAt(next);
  }

  activeHosts() {
    const now = Date.now();
    return this.state.getWebSockets("host").filter((socket) => {
      const info = socket.deserializeAttachment() || {};
      if (info.ended) return false;
      // Ключ ещё не предъявлен: хостом не считается (не получает запросы, его кадры отбрасываются).
      if (info.auth === "pending") return false;
      // Existing connections get one grace period when upgraded.
      if (info.lastSeen == null) socket.serializeAttachment({ ...info, lastSeen: now });
      if (socket.readyState === 1 && now - (info.lastSeen ?? now) < HOST_TIMEOUT_MS) return true;
      this.closed(socket);
      try { socket.close(1001, "Broadcast timed out"); } catch (_) {}
      return false;
    });
  }

  async ensureAlarm() {
    if (await this.state.storage.getAlarm() == null) {
      await this.state.storage.setAlarm(Date.now() + HOST_CHECK_MS);
    }
  }

  async alarm() {
    await this.alarmCore();
    this.reapUnauthenticated();
    this.flushRequests();
    await this.rearm();
  }

  async alarmCore() {
    // После выгрузки объекта из памяти отметка обрыва берётся из хранилища.
    if (this.hostLostAt == null) this.hostLostAt = (await this.state.storage.get("hostLostAt")) ?? null;
    if (!this.activeHosts().length && this.hostLostAt) {
      if (Date.now() - this.hostLostAt >= HOST_GRACE_MS) {
        this.hostLostAt = null;
        await this.state.storage.delete("hostLostAt");
        this.endViewers();
      } else {
        await this.state.storage.setAlarm(this.hostLostAt + HOST_GRACE_MS + 1000);
      }
      return;
    }
    if (this.activeHosts().length) {
      this.expireViewers();
      for (const viewer of this.activeViewers()) {
        try { viewer.send(JSON.stringify({ type: "heartbeat" })); }
        catch (_) { this.closed(viewer); }
      }
      // Older clients resend their last frame on a viewers update, even on a static screen.
      this.notifyHost();
      await this.state.storage.setAlarm(Date.now() + HOST_CHECK_MS);
    }
  }

  expireViewers() {
    const now = Date.now();
    this.reapUnauthenticated();
    for (const socket of this.state.getWebSockets("viewer")) {
      const info = socket.deserializeAttachment() || {};
      if (info.ended) continue;
      // One grace period for connections created before heartbeat support.
      if (info.lastSeen == null) socket.serializeAttachment({ ...info, lastSeen: now });
      if (socket.readyState === 1 && now - (info.lastSeen ?? now) < VIEWER_TIMEOUT_MS) continue;
      this.closed(socket);
      try { socket.close(1001, "Viewer timed out"); } catch (_) {}
    }
  }

  activeViewers() {
    return this.state.getWebSockets("viewer").filter((s) =>
      s.readyState === 1 && !s.deserializeAttachment()?.ended &&
      Date.now() - (s.deserializeAttachment()?.lastSeen ?? Date.now()) < VIEWER_TIMEOUT_MS);
  }

  approvedViewers() {
    return this.activeViewers().filter((s) => s.deserializeAttachment()?.approved);
  }

  toHost(message) {
    for (const host of this.activeHosts()) {
      try { host.send(JSON.stringify(message)); } catch (_) {}
    }
  }

  webSocketMessage(socket, message) {
    if (this.state.getTags(socket).includes("host")) {
      const info = socket.deserializeAttachment() || {};
      if (info.ended) return;
      if (info.auth === "pending") {
        // До проверки ключа принимается только auth; остальное, включая кадры, отбрасывается.
        if (typeof message !== "string" || message.length > 4096) return;
        let command;
        try { command = JSON.parse(message); } catch (_) { return; }
        if (command && command.type === "auth") return this.handleHostAuth(socket, command);
        return;
      }
      // Кадры идут десятки раз в секунду: метку «жив» обновляем не чаще раза в секунду (таймаут — минуты).
      if (typeof message === "string" || Date.now() - (info.lastSeen ?? 0) > 1000) socket.serializeAttachment({ ...info, lastSeen: Date.now() });
      if (typeof message === "string") return this.hostCommand(message, socket);
      for (const viewer of this.approvedViewers()) {
        try { viewer.send(message); } catch (_) { /* зритель отвалился */ }
      }
      return;
    }
    // Зритель: метки и рисунки (короткий JSON) — только от пущенных, ведущему и остальным пущенным.
    if (typeof message !== "string" || message.length > 32768) return;
    const info = socket.deserializeAttachment();
    if (socket.readyState !== 1 || !info || info.ended) return;
    let command;
    try { command = JSON.parse(message); } catch (_) { return; }
    if (!command || typeof command !== "object") return;
    if (command.type === "heartbeat") {
      socket.serializeAttachment({ ...info, lastSeen: Date.now() });
      return;
    }
    // До проверки ключа разрешены только auth и heartbeat; auth принимается один раз на сокет.
    if (info.auth === "pending") {
      if (command.type !== "auth" || !takeToken(socket)) return;
      return this.handleViewerAuth(socket, command);
    }
    if (command.type === "auth" && info.auth === "key") {
      try { socket.close(4400, "auth twice"); } catch (_) {}
      return;
    }
    if (!info.approved) return;
    socket.serializeAttachment({ ...info, lastSeen: Date.now() });
    if (!takeToken(socket)) return;
    // Игра (крестики-нолики) — только ведущему, с ID и именем зрителя, которым нельзя подменить.
    if (command.type === "game") {
      const fields = sanitizeGame(command);
      if (!fields) return;
      const game = JSON.stringify({ ...fields, from: info.id || "", name: info.name || "", ...(info.auth === "key" ? { fp: info.fp } : {}) });
      for (const host of this.activeHosts()) {
        try { host.send(game); } catch (_) {}
      }
      return;
    }
    // Дальше — только метки; служебные типы (viewers, request, ended…) зритель слать не может.
    const mark = sanitizeMark(command);
    if (!mark) return;
    const text = JSON.stringify(mark);
    for (const other of [...this.activeHosts(), ...this.approvedViewers()]) {
      if (other !== socket) {
        try { other.send(text); } catch (_) {}
      }
    }
  }

  // hostSocket — сокет отправителя (обязателен, N4). Хосту с проверенным ключом rid обязателен; старым — как раньше.
  hostCommand(text, hostSocket) {
    const hostInfo = (hostSocket && hostSocket.deserializeAttachment()) || {};
    const keyed = hostInfo.auth === "key";
    let command;
    try { command = JSON.parse(text); } catch (_) { return; }
    if (!command || typeof command !== "object") return;
    if (command.type === "heartbeat") return;
    if (command.type === "release" && keyed) return this.releaseOwner(hostSocket);
    // Игра ведущего — только выбранному зрителю (все его подключения).
    if (command.type === "game") {
      const { to, ...rest } = command;
      const game = JSON.stringify({ ...rest, from: "host" });
      for (const viewer of this.approvedViewers()) {
        const info = viewer.deserializeAttachment() || {};
        if (info.id && info.id === to) { try { viewer.send(game); } catch (_) {} }
      }
      return;
    }
    if (command.type !== "accept" && command.type !== "decline") return;
    if (keyed && typeof command.rid !== "string") return;
    // Отвечаем одному ожидающему сокету: по rid, если ведущий его вернул, иначе самому раннему с этим id.
    const target = this.activeViewers().find((viewer) => {
      const info = viewer.deserializeAttachment() || {};
      if (info.approved || info.id !== command.viewer) return false;
      // Запрос хосту ещё не отправлен (проверка ключа или очередь): отвечать рано.
      if (info.auth === "pending" || info.reqSent === false) return false;
      // rid есть, но не строка — не совпадение; fallback на самый ранний сокет только для команд без rid.
      if (command.rid === undefined) return true;
      return typeof command.rid === "string" && info.rid === command.rid;
    });
    for (const viewer of target ? [target] : []) {
      const info = viewer.deserializeAttachment() || {};
      if (command.type === "accept") {
        // Кто пустил: при смене хоста (в том числе в grace) пущенные чужим ключом завершаются (M2).
        viewer.serializeAttachment({ ...info, approved: true, approvedBy: keyed ? hostInfo.pub : "none" });
        const accepted = { type: "accepted", name: command.name || "" };
        // Подпись хоста (accept\n<room>\n<pub зрителя>\n<rid>): зритель сверит её с hostKey, relay подделать её не может.
        if (info.auth === "key" && typeof command.hostSig === "string" && b64uHasLength(command.hostSig, 64)) {
          accepted.hostSig = command.hostSig;
        }
        viewer.send(JSON.stringify(accepted));
      } else if (command.type === "decline") {
        const key = info.pub ? `k:${info.pub}` : (info.ip ? `ip:${info.ip}` : "");
        if (key) noteDecline(this.declines, key, Date.now());
        try {
          viewer.serializeAttachment({ ...info, ended: true });
          viewer.send(JSON.stringify({ type: "declined" }));
          viewer.close(1000, "Declined");
        } catch (_) {}
      }
    }
    this.notifyHost();
  }

  // «Сменить ID»: хост с проверенным ключом освобождает ID; трансляция заканчивается.
  async releaseOwner(socket) {
    const info = socket.deserializeAttachment() || {};
    // Через ту же цепочку, что и привязка: параллельный claim не запишет ключ поверх удаления (N6).
    await this.serial(async () => {
      const owner = await this.readOwner();
      if (owner && owner.pub === info.pub) await this.state.storage.delete("owner");
    });
    this.closed(socket, true);
    try { socket.close(1000, "ID released"); } catch (_) {}
  }

  webSocketClose(socket, code) {
    // 1000 — ведущий сам нажал «Стоп»: заканчиваем сразу. Иначе — обрыв, даём время переподключиться.
    this.closed(socket, code === 1000);
  }

  webSocketError(socket) {
    this.closed(socket);
  }

  endViewers() {
    for (const viewer of this.state.getWebSockets("viewer")) this.endViewer(viewer);
  }

  endViewer(viewer) {
    try {
      viewer.serializeAttachment({ ...viewer.deserializeAttachment(), ended: true });
      viewer.send(JSON.stringify({ type: "ended" }));
      viewer.close(1000, "Broadcast ended");
    } catch (_) {}
  }

  closed(socket, explicit = false) {
    if (this.state.getTags(socket).includes("host")) {
      const info = socket.deserializeAttachment() || {};
      if (info.ended) return;
      socket.serializeAttachment({ ...info, ended: true });
      // Хост, не прошедший проверку, комнату не держал: обрыва и ожидания нет.
      if (info.auth === "pending") return;
      if (explicit) {
        this.hostLostAt = null;
        this.state.storage.delete("hostLostAt");
        this.endViewers();
        return;
      }
      // Обрыв: зрители остаются и видят «переподключение»; не вернётся за HOST_GRACE_MS — конец.
      this.hostLostAt = Date.now();
      this.state.storage.put("hostLostAt", this.hostLostAt);
      for (const viewer of this.activeViewers()) {
        try { viewer.send(JSON.stringify({ type: "reconnecting" })); } catch (_) {}
      }
      this.state.storage.setAlarm(Date.now() + HOST_GRACE_MS + 1000);
    } else {
      const info = socket.deserializeAttachment() || {};
      if (info.ended) return;
      socket.serializeAttachment({ ...info, ended: true });
      // Хосту запрос не уходил (нет ключа или очередь) — и отменять нечего.
      if (!info.approved && info.auth !== "pending" && info.reqSent !== false) {
        this.toHost({ type: "cancelled", viewer: info.id, rid: info.rid });
      }
      this.notifyHost(socket);
    }
  }

  notifyHost(leaving) {
    const watching = this.approvedViewers().filter((s) => s !== leaving);
    // Count viewer devices, not overlapping sockets after a reconnect.
    // Anonymous legacy viewers remain separate rather than sharing an empty ID.
    const people = [...new Map(watching.map((s) => {
      const info = s.deserializeAttachment();
      return [info.id || s, { id: info.id, name: info.name, h264: !!info.h264, ...(info.auth === "key" ? { fp: info.fp, auth: "key" } : {}) }];
    })).values()];
    this.toHost({
      type: "viewers",
      count: people.length,
      list: people,
    });
  }
}
