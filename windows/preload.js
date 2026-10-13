const { contextBridge, ipcRenderer } = require("electron");

// То, что страница ретранслятора может попросить у приложения.
contextBridge.exposeInMainWorld("mu", {
  version: require("./package.json").version,
  sources: () => ipcRenderer.invoke("sources"),
  choose: (id, audio) => ipcRenderer.invoke("choose", id, audio),
});
