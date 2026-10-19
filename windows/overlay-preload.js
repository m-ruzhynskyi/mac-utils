const { contextBridge, ipcRenderer } = require("electron");
contextBridge.exposeInMainWorld("overlay", {
  onMark: (callback) => ipcRenderer.on("mark", (_e, mark) => callback(mark)),
  // Где транслируемая область в окне меток (CSS-пиксели): метки ставятся в неё, а не на всё окно.
  onRegion: (callback) => ipcRenderer.on("region", (_e, region) => callback(region)),
});
