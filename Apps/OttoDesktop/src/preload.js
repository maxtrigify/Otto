'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('otto', {
  state: () => ipcRenderer.invoke('app:state'),
  chooseWorkspace: () => ipcRenderer.invoke('workspace:choose'),
  launch: (agentID, columns, rows) => ipcRenderer.invoke('session:launch', { agentID, columns, rows }),
  input: (sessionID, text) => ipcRenderer.invoke('session:input', { sessionID, text }),
  resize: (sessionID, columns, rows) => ipcRenderer.invoke('session:resize', { sessionID, columns, rows }),
  stop: (sessionID) => ipcRenderer.invoke('session:stop', { sessionID }),
  openLink: (url) => ipcRenderer.invoke('link:open', url),
  onEvent: (listener) => ipcRenderer.on('ottod:event', (_event, payload) => listener(payload)),
  onExit: (listener) => ipcRenderer.on('ottod:exit', (_event, payload) => listener(payload)),
});
