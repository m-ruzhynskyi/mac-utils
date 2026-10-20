const { contextBridge, ipcRenderer } = require("electron");
contextBridge.exposeInMainWorld("overlay", {
  onMark: (callback) => ipcRenderer.on("mark", (_e, mark) => callback(mark)),
  // Где транслируемая область в окне меток (доли окна): метки ставятся в неё, а не на всё окно.
  onRegion: (callback) => ipcRenderer.on("region", (_e, region) => callback(region)),
  // Зритель переключил монитор: «‹имя› переключает на монитор N» в углу, без кнопок.
  onNotice: (callback) => ipcRenderer.on("notice", (_e, notice) => callback(notice)),
  // Где страница меток на самом деле нарисовала метку (только числа) — в журнал разбора overlay.log.
  report: (data) => ipcRenderer.send("overlay-report", data),
});
