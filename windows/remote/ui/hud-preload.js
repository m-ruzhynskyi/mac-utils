"use strict";
const { contextBridge, ipcRenderer } = require("electron");
contextBridge.exposeInMainWorld("hud", {
  onState: (fn) => ipcRenderer.on("rc:hud", (_e, state) => fn(state)),
  action: (id) => ipcRenderer.send("rc:hudAction", id),
  size: (height) => ipcRenderer.send("rc:hudSize", Number(height)),
});
