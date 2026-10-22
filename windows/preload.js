const { contextBridge, ipcRenderer } = require("electron");

// То, что страница ретранслятора может попросить у приложения.
contextBridge.exposeInMainWorld("mu", {
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
  // Где ведущий видит метки: { screen: false, reason } — поверх экрана нельзя (исключение из захвата не встало), страница
  // рисует их у себя.
  onMarksState: (callback) => { ipcRenderer.removeAllListeners("marks-state"); ipcRenderer.on("marks-state", (_e, state) => callback(state)); },
  stopped: () => { ipcRenderer.removeAllListeners("audio"); ipcRenderer.send("stopped"); },
  // Зрители переключают мониторы ведущего: список (без имён и ID устройств), его изменения, выбор монитора по номеру
  // и уведомление ведущему в окне меток.
  displays: () => ipcRenderer.invoke("displays"),
  onDisplays: (callback) => { ipcRenderer.removeAllListeners("displays-changed"); ipcRenderer.on("displays-changed", () => callback()); },
  switchTo: (n) => ipcRenderer.invoke("switchTo", n),
  notice: (data) => ipcRenderer.send("notice", data),
  // Журнал кодера трансляции (только коды и числа) — в overlay.log.
  log: (line) => ipcRenderer.send("page-log", String(line).slice(0, 400)),
});
