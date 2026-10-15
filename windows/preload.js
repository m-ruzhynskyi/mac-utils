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
  stopped: () => { ipcRenderer.removeAllListeners("audio"); ipcRenderer.send("stopped"); },
});
