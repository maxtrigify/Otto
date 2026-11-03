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
  // Voice: microphone audio out, speaker audio and state in, dictation.
  voiceMic: (pcm) => ipcRenderer.send('voice:mic', pcm),
  voiceSpeech: () => ipcRenderer.send('voice:speech'),
  voiceAnswer: (answer) => ipcRenderer.send('voice:answer', answer),
  onVoiceAudio: (listener) => ipcRenderer.on('voice:audio', (_event, payload) => listener(payload)),
  onVoiceState: (listener) => ipcRenderer.on('voice:state', (_event, payload) => listener(payload)),
  transcribe: (audio, mimeType) => ipcRenderer.invoke('voice:transcribe', { audio, mimeType }),
  keychain: () => ipcRenderer.invoke('voice:keychain'),
  // Updates for installed builds.
  updateState: () => ipcRenderer.invoke('update:state'),
  checkForUpdate: () => ipcRenderer.invoke('update:check'),
  downloadUpdate: () => ipcRenderer.invoke('update:download'),
  installUpdate: () => ipcRenderer.invoke('update:install'),
  onUpdate: (listener) => ipcRenderer.on('update:state', (_event, payload) => listener(payload)),
  browserShow: (nodeID, bounds) => ipcRenderer.invoke('browser:show', { nodeID, bounds }),
  browserHide: () => ipcRenderer.invoke('browser:hide'),
  browserList: () => ipcRenderer.invoke('browser:list'),
  browserSync: () => ipcRenderer.invoke('browser:sync'),
  onBrowserState: (listener) => ipcRenderer.on('browser:state', (_event, payload) => listener(payload)),
  onEvent: (listener) => ipcRenderer.on('ottod:event', (_event, payload) => listener(payload)),
  onExit: (listener) => ipcRenderer.on('ottod:exit', (_event, payload) => listener(payload)),
});
