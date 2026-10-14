const { contextBridge, ipcRenderer } = require("electron");
contextBridge.exposeInMainWorld("overlay", { onMark: (callback) => ipcRenderer.on("mark", (_e, mark) => callback(mark)) });
