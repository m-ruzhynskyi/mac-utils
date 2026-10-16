const { contextBridge, ipcRenderer } = require("electron");

// Ключ устройства есть, только если safeStorage доступен: иначе приложение работает как mu-share-1 и этих функций у страницы нет
// (страница берёт ID из localStorage, подписей не просит, а main.js не ставит токен mu-share-2).
// Только на странице ретранслятора: на чужой странице (и на offline.html) API ключа не выдаётся; main проверяет отправителя сам.
const RELAY_ORIGIN = "https://mac-utils-relay.mako-62d.workers.dev";
const keysAvailable = window.location.origin === RELAY_ORIGIN && ipcRenderer.sendSync("identity-available") === true;

// Прежний ID страницы (localStorage «mu-id»): main перенесёт его к себе, чтобы ID не поменялся после обновления.
function legacyId() {
  try {
    const id = JSON.parse(window.localStorage.getItem("mu-id"));
    return typeof id === "string" ? id : null;
  } catch (_) { return null; }
}

const keyApi = keysAvailable ? {
  // Свой ID (10 цифр) — синхронно. Его хранит main рядом с ключом.
  myId: () => ipcRenderer.sendSync("myId", legacyId()),
  identity: () => ipcRenderer.invoke("identity"),
  // Канонические строки протокола собирает main; произвольные байты страница подписать не может.
  signHost: (roomId, nonce) => ipcRenderer.invoke("signHost", roomId, nonce),
  signViewer: (roomId, viewerId, rid, nonce) => ipcRenderer.invoke("signViewer", roomId, viewerId, rid, nonce),
  signStatus: (myId, ts, idsCsv) => ipcRenderer.invoke("signStatus", myId, ts, idsCsv),
  // «Получить новый ID»: новый ключ и ID.
  resetId: () => ipcRenderer.invoke("resetId"),
} : {};

// То, что страница ретранслятора может попросить у приложения.
contextBridge.exposeInMainWorld("mu", {
  ...keyApi,
  // В изолированном preload нельзя require локальных файлов — версию спрашиваем у приложения.
  version: ipcRenderer.sendSync("version"),
  hostname: ipcRenderer.sendSync("hostname"),
  attention: () => ipcRenderer.send("attention"),
  sources: () => ipcRenderer.invoke("sources"),
  choose: (id, audio, muted) => ipcRenderer.invoke("choose", id, audio, muted),
  // Не передавать звук выбранных программ: список программ со звуком и поток звука без них.
  audioApps: () => ipcRenderer.invoke("audioApps"),
  startAudio: (onChunk) => {
    ipcRenderer.removeAllListeners("audio");
    ipcRenderer.on("audio", (_e, data) => onChunk(data));
    ipcRenderer.send("startAudio");
  },
  setMuted: (muted) => ipcRenderer.send("setMuted", muted),
  // Метки зрителей — на экран ведущего; трансляция закончилась — убрать окно меток.
  mark: (mark) => ipcRenderer.send("mark", mark),
  stopped: () => { ipcRenderer.removeAllListeners("audio"); ipcRenderer.send("stopped"); },
});
