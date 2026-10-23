// Мост окна «Удалённые подключения» и палитры: только вызовы к основному процессу. Пароли сюда не приходят; «Доступ» — только по
// «Показать» в подробностях (revealAccess) и живёт в окне, пока они открыты.
"use strict";
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("rc", {
  view: (query, filter, tags) => ipcRenderer.invoke("rc:view", { query, filter, tags: Array.isArray(tags) ? tags : [] }),
  details: (key) => ipcRenderer.invoke("rc:details", key),
  pendingDetails: () => ipcRenderer.invoke("rc:pendingDetails"),
  revealAccess: (key) => ipcRenderer.invoke("rc:revealAccess", key),
  copySecret: (key, field) => ipcRenderer.invoke("rc:copySecret", { key, field }),
  copyAddress: (key) => ipcRenderer.invoke("rc:copyAddress", key),
  openRDP: (key) => ipcRenderer.invoke("rc:openRDP", key),
  rowMenu: (key) => ipcRenderer.invoke("rc:rowMenu", key),
  onMenu: (fn) => { ipcRenderer.removeAllListeners("rc:menu"); ipcRenderer.on("rc:menu", (_e, m) => fn(m && { action: String(m.action), key: String(m.key) })); },
  onDetails: (fn) => { ipcRenderer.removeAllListeners("rc:details"); ipcRenderer.on("rc:details", () => fn()); },
  toggleFavorite: (key) => ipcRenderer.invoke("rc:toggleFavorite", key),
  connect: (key, noPassword) => ipcRenderer.invoke("rc:connect", { key, noPassword: !!noPassword }),
  openFile: () => ipcRenderer.invoke("rc:openFile"),
  reload: () => ipcRenderer.invoke("rc:reload"),
  chooseFile: () => ipcRenderer.invoke("rc:chooseFile"),
  getSettings: () => ipcRenderer.invoke("rc:getSettings"),
  setSettings: (patch) => ipcRenderer.invoke("rc:setSettings", patch),
  createTemplate: (kind) => ipcRenderer.invoke("rc:createTemplate", kind),
  sheets: () => ipcRenderer.invoke("rc:sheets"),
  edit: (action, payload) => ipcRenderer.invoke("rc:edit", { action, payload }),
  closePalette: () => ipcRenderer.send("rc:closePalette"),
  onChanged: (fn) => { ipcRenderer.removeAllListeners("rc:changed"); ipcRenderer.on("rc:changed", () => fn()); },
  onShow: (fn) => { ipcRenderer.removeAllListeners("rc:show"); ipcRenderer.on("rc:show", () => fn()); },
});
