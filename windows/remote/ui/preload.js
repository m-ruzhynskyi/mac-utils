// Мост окна «Удалённые подключения» и палитры: только вызовы к основному процессу, пароль сюда не приходит.
"use strict";
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("rc", {
  view: (query, filter) => ipcRenderer.invoke("rc:view", { query, filter }),
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
