'use strict';

// The private sign-in window's bar: Done or Cancel, and errors from the engine.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('signIn', {
  answer: (accountID, done) => ipcRenderer.send('signin:answer', { accountID, done }),
  onError: (listener) => ipcRenderer.on('signin:error', (_event, message) => listener(message)),
});
