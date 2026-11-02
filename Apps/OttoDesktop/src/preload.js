'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('otto', {
  state: () => ipcRenderer.invoke('app:state'),
  chooseWorkspace: () => ipcRenderer.invoke('workspace:choose'),
  // Chats: the engine's host RPC (allowlisted in the main process).
  engine: (method, parameters) => ipcRenderer.invoke('engine:call', { method, parameters }),
  // Home and Documents: owner-only methods on the same engine.
  desktop: (method, params) => ipcRenderer.invoke('engine:desktop', { method, params }),
  onEngineExit: (listener) => ipcRenderer.on('engine:exit', (_event, payload) => listener(payload)),
  // Terminals: raw sessions through ottod.
  launch: (agentID, columns, rows, signIn = false) =>
    ipcRenderer.invoke('session:launch', { agentID, columns, rows, signIn }),
  input: (sessionID, text) => ipcRenderer.invoke('session:input', { sessionID, text }),
  resize: (sessionID, columns, rows) => ipcRenderer.invoke('session:resize', { sessionID, columns, rows }),
  stop: (sessionID) => ipcRenderer.invoke('session:stop', { sessionID }),
  openLink: (url) => ipcRenderer.invoke('link:open', url),
  // Browser: the engine's browsers, drawn by the main process over the page area.
  browserShow: (nodeID, bounds) => ipcRenderer.invoke('browser:show', { nodeID, bounds }),
  browserHide: () => ipcRenderer.invoke('browser:hide'),
  browserList: () => ipcRenderer.invoke('browser:list'),
  browserSync: () => ipcRenderer.invoke('browser:sync'),
  onBrowserState: (listener) => ipcRenderer.on('browser:state', (_event, payload) => listener(payload)),
  onEvent: (listener) => ipcRenderer.on('ottod:event', (_event, payload) => listener(payload)),
  onExit: (listener) => ipcRenderer.on('ottod:exit', (_event, payload) => listener(payload)),
});
