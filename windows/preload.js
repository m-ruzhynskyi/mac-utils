const { contextBridge, ipcRenderer } = require("electron");

// То, что страница ретранслятора может попросить у приложения.
contextBridge.exposeInMainWorld("mu", {
  // В изолированном preload нельзя require локальных файлов — версию спрашиваем у приложения.
  version: ipcRenderer.sendSync("version"),
  hostname: ipcRenderer.sendSync("hostname"),
  attention: () => ipcRenderer.send("attention"),
  sources: () => ipcRenderer.invoke("sources"),
  choose: (id, audio) => ipcRenderer.invoke("choose", id, audio),
  // Метки зрителей — на экран ведущего; трансляция закончилась — убрать окно меток.
  mark: (mark) => ipcRenderer.send("mark", mark),
  stopped: () => ipcRenderer.send("stopped"),
});
