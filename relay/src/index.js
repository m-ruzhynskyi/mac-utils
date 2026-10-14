// Ретранслятор трансляции экрана Mac Utils.
// Ведущий подключается к /room/<код>?role=host и шлёт кадры (JPEG) двоичными сообщениями,
// зрители — к /room/<код>?role=viewer и получают их. Комната живёт, пока подключён ведущий.
// Сервер кадры не хранит и не разбирает — только пересылает.
// Формат двоичных сообщений: первый байт — тип (1 — кадр JPEG, 2 — звук PCM 16 бит, 24 кГц, моно).
// «/» — веб-страница: смотреть и транслировать из браузера (Windows, Linux, любой компьютер).

import page from "./index.html";
import landing from "./landing.html";

// Смотреть и транслировать можно только из приложений Mac Utils (Mac) и Mac Utils Share (Windows):
// они добавляют этот заголовок к каждому запросу. В обычном браузере — страница со ссылками на приложения.
const CLIENT_HEADER = "x-macutils-client";
const CLIENT_TOKEN = "mu-share-1";

function isClient(request) {
  return request.headers.get(CLIENT_HEADER) === CLIENT_TOKEN;
}

const MAX_VIEWERS = 10;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/room\/(\d{6})$/);
    if (!match) {
      return new Response(isClient(request) ? page : landing, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }
    if (!isClient(request)) return new Response("Use the Mac Utils app", { status: 403 });
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }
    const room = env.ROOMS.get(env.ROOMS.idFromName(match[1]));
    return room.fetch(request);
  },
};

export class Room {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const role = new URL(request.url).searchParams.get("role");
    const hosts = this.state.getWebSockets("host");
    if (role === "host" && hosts.length > 0) return new Response("Room is busy", { status: 409 });
    if (role !== "host") {
      if (hosts.length === 0) return new Response("No broadcast with this code", { status: 404 });
      if (this.state.getWebSockets("viewer").length >= MAX_VIEWERS) {
        return new Response("Too many viewers", { status: 429 });
      }
    }
    const [client, server] = Object.values(new WebSocketPair());
    this.state.acceptWebSocket(server, [role === "host" ? "host" : "viewer"]);
    if (role !== "host") this.notifyHost();
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(socket, message) {
    if (this.state.getTags(socket).includes("host")) {
      for (const viewer of this.state.getWebSockets("viewer")) {
        try { viewer.send(message); } catch (_) { /* зритель отвалился */ }
      }
      return;
    }
    // Зритель: метки и рисунки (короткий JSON) — ведущему и остальным зрителям.
    if (typeof message !== "string" || message.length > 32768) return;
    for (const other of this.state.getWebSockets()) {
      if (other !== socket) {
        try { other.send(message); } catch (_) {}
      }
    }
  }

  webSocketClose(socket) {
    this.closed(socket);
  }

  webSocketError(socket) {
    this.closed(socket);
  }

  closed(socket) {
    if (this.state.getTags(socket).includes("host")) {
      for (const viewer of this.state.getWebSockets("viewer")) {
        try {
          viewer.send(JSON.stringify({ type: "ended" }));
          viewer.close(1000, "Broadcast ended");
        } catch (_) {}
      }
    } else {
      this.notifyHost(socket);
    }
  }

  notifyHost(leaving) {
    const count = this.state.getWebSockets("viewer").filter((s) => s !== leaving).length;
    for (const host of this.state.getWebSockets("host")) {
      try { host.send(JSON.stringify({ type: "viewers", count })); } catch (_) {}
    }
  }
}
