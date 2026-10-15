// Ретранслятор трансляции экрана Mac Utils (по принципу AnyDesk).
// У каждого пользователя постоянный 10-значный ID — это и есть его «комната».
// Ведущий: /room/<ID>?role=host. Зритель: /room/<ID>?role=viewer&viewer=<свой ID>&name=<имя компьютера>.
// Зритель ждёт, пока ведущий его пустит: ведущему приходит {"type":"request"}, он отвечает
// {"type":"accept"|"decline","viewer":"…","name":"<имя ведущего>"}. Кадры и звук идут только пущенным зрителям.
// Двоичные сообщения: первый байт — тип (1 — кадр JPEG, 2 — звук PCM 16 бит, 24 кГц, моно).
// Текст от пущенных зрителей (метки {"type":"ping"|"stroke"}) — ведущему и остальным зрителям.
// /status?ids=a,b,c — кто из них сейчас в эфире (для отметок в истории).
// Сервер ничего не хранит и не разбирает — только пересылает.

import page from "./index.html";
import landing from "./landing.html";

// Смотреть и транслировать можно только из приложений Mac Utils (Mac) и Mac Utils Share (Windows):
// они добавляют этот заголовок к каждому запросу. В обычном браузере — страница со ссылками на приложения.
const CLIENT_HEADER = "x-macutils-client";
const CLIENT_TOKEN = "mu-share-1";
const MAX_VIEWERS = 10;
const HOST_TIMEOUT_MS = 120_000;
// Связь с ведущим оборвалась не по «Стоп» — ждём, пока он переподключится, зрители не отключаются.
const HOST_GRACE_MS = 45_000;
const HOST_CHECK_MS = 30_000;
const VIEWER_TIMEOUT_MS = 120_000;
const ID = /^\d{6}$|^\d{10}$/;

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

function isClient(request) {
  return request.headers.get(CLIENT_HEADER) === CLIENT_TOKEN;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const room = url.pathname.match(/^\/room\/(\d+)$/);
    if (url.pathname === "/status") {
      if (!isClient(request)) return new Response("Use the Mac Utils app", { status: 403 });
      const ids = (url.searchParams.get("ids") || "").split(",").filter((id) => ID.test(id)).slice(0, 50);
      const result = {};
      const revisions = new Set();
      await Promise.all(ids.map(async (id) => {
        const response = await env.ROOMS.get(env.ROOMS.idFromName(id)).fetch("https://room/live");
        revisions.add(response.headers.get("x-relay-revision") || "legacy");
        result[id] = (await response.text()) === "1";
      }));
      return Response.json(result, { headers: { "cache-control": "no-store", "x-relay-room-revision": [...revisions].join(",") } });
    }
    if (!room || !ID.test(room[1])) {
      return new Response(isClient(request) ? page : landing, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }
    if (!isClient(request)) return new Response("Use the Mac Utils app", { status: 403 });
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }
    return env.ROOMS.get(env.ROOMS.idFromName(room[1])).fetch(request);
  },
};

export class Room {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const url = new URL(request.url);
    this.expireViewers();
    const hosts = this.activeHosts();
    if (hosts.length) await this.ensureAlarm();
    if (url.pathname === "/live") return new Response(hosts.length > 0 ? "1" : "0", { headers: { "x-relay-revision": "viewer-heartbeat-1" } });

    const role = url.searchParams.get("role");
    if (role === "host" && hosts.length > 0) return new Response("Room is busy", { status: 409 });
    if (role !== "host") {
      if (hosts.length === 0) return new Response("No broadcast with this ID", { status: 404 });
      if (this.activeViewers().length >= MAX_VIEWERS) {
        return new Response("Too many viewers", { status: 429 });
      }
    }
    const [client, server] = Object.values(new WebSocketPair());
    if (role === "host") {
      this.state.acceptWebSocket(server, ["host"]);
      server.serializeAttachment({ lastSeen: Date.now() });
      if (this.hostLostAt ?? (await this.state.storage.get("hostLostAt"))) {
        this.hostLostAt = null;
        await this.state.storage.delete("hostLostAt");
        for (const viewer of this.activeViewers()) {
          try { viewer.send(JSON.stringify({ type: "resumed" })); } catch (_) {}
        }
      }
      await this.ensureAlarm();
    } else {
      let viewer = (url.searchParams.get("viewer") || "").replace(/\D/g, "").slice(0, 10);
      // ID комнаты как ID зрителя — подделка (его знает любой, у кого есть код): старые Mac-хосты 1.3.x
      // принимали такого «себя» без вопроса. Отдаём хосту пустой ID, он покажет обычный запрос.
      if (viewer === (url.pathname.match(/^\/room\/(\d+)$/) || [])[1]) viewer = "";
      const name = (url.searchParams.get("name") || "Без имени").slice(0, 60);
      this.state.acceptWebSocket(server, ["viewer"]);
      // h264=1 — зритель понимает видео H.264; старые версии понимают только кадры JPEG.
      const h264 = url.searchParams.get("h264") === "1";
      const rid = crypto.randomUUID();
      server.serializeAttachment({ id: viewer, name, h264, rid, approved: false, lastSeen: Date.now() });
      server.send(JSON.stringify({ type: "waiting" }));
      this.toHost({ type: "request", viewer, name, rid });
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  activeHosts() {
    const now = Date.now();
    return this.state.getWebSockets("host").filter((socket) => {
      const info = socket.deserializeAttachment() || {};
      if (info.ended) return false;
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
      socket.serializeAttachment({ ...info, lastSeen: Date.now() });
      if (typeof message === "string") return this.hostCommand(message);
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
    if (command.type === "heartbeat") {
      socket.serializeAttachment({ ...info, lastSeen: Date.now() });
      return;
    }
    if (!info.approved) return;
    socket.serializeAttachment({ ...info, lastSeen: Date.now() });
    if (!takeToken(socket)) return;
    // Игра (крестики-нолики) — только ведущему, с ID и именем зрителя, которым нельзя подменить.
    if (command.type === "game") {
      const fields = sanitizeGame(command);
      if (!fields) return;
      const game = JSON.stringify({ ...fields, from: info.id || "", name: info.name || "" });
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

  hostCommand(text) {
    let command;
    try { command = JSON.parse(text); } catch (_) { return; }
    if (command.type === "heartbeat") return;
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
    // Отвечаем одному ожидающему сокету: по rid, если ведущий его вернул, иначе самому раннему с этим id.
    const target = this.activeViewers().find((viewer) => {
      const info = viewer.deserializeAttachment() || {};
      if (info.approved || info.id !== command.viewer) return false;
      // rid есть, но не строка — не совпадение; fallback на самый ранний сокет только для команд без rid.
      if (command.rid === undefined) return true;
      return typeof command.rid === "string" && info.rid === command.rid;
    });
    for (const viewer of target ? [target] : []) {
      const info = viewer.deserializeAttachment() || {};
      if (command.type === "accept") {
        viewer.serializeAttachment({ ...info, approved: true });
        viewer.send(JSON.stringify({ type: "accepted", name: command.name || "" }));
      } else if (command.type === "decline") {
        try {
          viewer.serializeAttachment({ ...info, ended: true });
          viewer.send(JSON.stringify({ type: "declined" }));
          viewer.close(1000, "Declined");
        } catch (_) {}
      }
    }
    this.notifyHost();
  }

  webSocketClose(socket, code) {
    // 1000 — ведущий сам нажал «Стоп»: заканчиваем сразу. Иначе — обрыв, даём время переподключиться.
    this.closed(socket, code === 1000);
  }

  webSocketError(socket) {
    this.closed(socket);
  }

  endViewers() {
    for (const viewer of this.state.getWebSockets("viewer")) {
      try {
        viewer.serializeAttachment({ ...viewer.deserializeAttachment(), ended: true });
        viewer.send(JSON.stringify({ type: "ended" }));
        viewer.close(1000, "Broadcast ended");
      } catch (_) {}
    }
  }

  closed(socket, explicit = false) {
    if (this.state.getTags(socket).includes("host")) {
      const info = socket.deserializeAttachment() || {};
      if (info.ended) return;
      socket.serializeAttachment({ ...info, ended: true });
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
      if (!info.approved) this.toHost({ type: "cancelled", viewer: info.id, rid: info.rid });
      this.notifyHost(socket);
    }
  }

  notifyHost(leaving) {
    const watching = this.approvedViewers().filter((s) => s !== leaving);
    // Count viewer devices, not overlapping sockets after a reconnect.
    // Anonymous legacy viewers remain separate rather than sharing an empty ID.
    const people = [...new Map(watching.map((s) => {
      const info = s.deserializeAttachment();
      return [info.id || s, { id: info.id, name: info.name, h264: !!info.h264 }];
    })).values()];
    this.toHost({
      type: "viewers",
      count: people.length,
      list: people,
    });
  }
}
