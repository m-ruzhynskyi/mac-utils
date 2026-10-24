// Мост окна «Удалённые подключения» и палитры: только вызовы к основному процессу. Пароли и ключи в карточку не приходят — только
// признак «есть»; значение — по 👁 на 10 с (revealSecret), копирует основной процесс (copySecret). «Доступ» — по «Показать», пароли
// под маской (revealAccess); шаги, учётки и контакты — при открытии подробностей (cardInfo). Всё это живёт в окне, пока подробности
// открыты.
"use strict";
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("rc", {
  view: (query, filter, tags) => ipcRenderer.invoke("rc:view", { query, filter, tags: Array.isArray(tags) ? tags : [] }),
  details: (key) => ipcRenderer.invoke("rc:details", key),
  pendingDetails: () => ipcRenderer.invoke("rc:pendingDetails"),
  revealAccess: (key) => ipcRenderer.invoke("rc:revealAccess", key),
  copySecret: (key, field, quiet) => ipcRenderer.invoke("rc:copySecret", { key, field, quiet: !!quiet }),
  revealSecret: (key, field) => ipcRenderer.invoke("rc:revealSecret", { key, field }),
  copyText: (text) => ipcRenderer.invoke("rc:copyText", String(text)),
  call: (phone) => ipcRenderer.invoke("rc:call", String(phone)),
  copyAddress: (key, fromAccess) => ipcRenderer.invoke("rc:copyAddress", { key, fromAccess: !!fromAccess }),
  copyPhone: (text) => ipcRenderer.invoke("rc:copyPhone", String(text)),
  cardInfo: (key) => ipcRenderer.invoke("rc:cardInfo", key),
  openRDP: (key, fromAccess) => ipcRenderer.invoke("rc:openRDP", { key, fromAccess: !!fromAccess }),
  showFolder: () => ipcRenderer.invoke("rc:showFolder"),
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
