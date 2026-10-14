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
const HOST_CHECK_MS = 30_000;
const VIEWER_TIMEOUT_MS = 120_000;
const ID = /^\d{6}$|^\d{10}$/;

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
      await Promise.all(ids.map(async (id) => {
        const response = await env.ROOMS.get(env.ROOMS.idFromName(id)).fetch("https://room/live");
        result[id] = (await response.text()) === "1";
      }));
      return Response.json(result, { headers: { "cache-control": "no-store" } });
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
    if (url.pathname === "/live") return new Response(hosts.length > 0 ? "1" : "0");

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
      await this.ensureAlarm();
    } else {
      const viewer = (url.searchParams.get("viewer") || "").replace(/\D/g, "").slice(0, 10);
      const name = (url.searchParams.get("name") || "Без имени").slice(0, 60);
      this.state.acceptWebSocket(server, ["viewer"]);
      server.serializeAttachment({ id: viewer, name, approved: false, lastSeen: Date.now() });
      server.send(JSON.stringify({ type: "waiting" }));
      this.toHost({ type: "request", viewer, name });
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
    for (const other of [...this.activeHosts(), ...this.approvedViewers()]) {
      if (other !== socket) {
        try { other.send(message); } catch (_) {}
      }
    }
  }

  hostCommand(text) {
    let command;
    try { command = JSON.parse(text); } catch (_) { return; }
    if (command.type === "heartbeat") return;
    for (const viewer of this.activeViewers()) {
      const info = viewer.deserializeAttachment() || {};
      if (info.id !== command.viewer || info.approved) continue;
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

  webSocketClose(socket) {
    this.closed(socket);
  }

  webSocketError(socket) {
    this.closed(socket);
  }

  closed(socket) {
    if (this.state.getTags(socket).includes("host")) {
      const info = socket.deserializeAttachment() || {};
      if (info.ended) return;
      socket.serializeAttachment({ ...info, ended: true });
      for (const viewer of this.state.getWebSockets("viewer")) {
        try {
          viewer.serializeAttachment({ ...viewer.deserializeAttachment(), ended: true });
          viewer.send(JSON.stringify({ type: "ended" }));
          viewer.close(1000, "Broadcast ended");
        } catch (_) {}
      }
    } else {
      const info = socket.deserializeAttachment() || {};
      if (info.ended) return;
      socket.serializeAttachment({ ...info, ended: true });
      if (!info.approved) this.toHost({ type: "cancelled", viewer: info.id });
      this.notifyHost(socket);
    }
  }

  notifyHost(leaving) {
    const watching = this.approvedViewers().filter((s) => s !== leaving);
    // Count viewer devices, not overlapping sockets after a reconnect.
    // Anonymous legacy viewers remain separate rather than sharing an empty ID.
    const people = [...new Map(watching.map((s) => {
      const info = s.deserializeAttachment();
      return [info.id || s, { id: info.id, name: info.name }];
    })).values()];
    this.toHost({
      type: "viewers",
      count: people.length,
      list: people,
    });
  }
}
