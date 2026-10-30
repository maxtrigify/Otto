'use strict';

const { app, BrowserWindow, dialog, ipcMain, shell } = require('electron');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { OttodClient } = require('./ottod');
const { loginEnvironment, discoverAgents } = require('./agents');

const isWindows = process.platform === 'win32';
let window = null;
let client = null;
let env = null;
let settings = null;

// Never share a data folder with the native Otto app (macOS uses "Application Support/Otto").
app.setPath('userData', path.join(app.getPath('appData'), 'Otto Desktop'));

const settingsPath = () => path.join(app.getPath('userData'), 'settings.json');

function loadSettings() {
  try {
    return JSON.parse(fs.readFileSync(settingsPath(), 'utf8'));
  } catch {
    return { workspace: null };
  }
}

function saveSettings() {
  fs.mkdirSync(path.dirname(settingsPath()), { recursive: true });
  fs.writeFileSync(settingsPath(), JSON.stringify(settings, null, 2));
}

/** Packaged builds ship ottod in resources/bin; development uses OTTOD_PATH or SwiftPM output. */
function ottodBinary() {
  const name = isWindows ? 'ottod.exe' : 'ottod';
  const candidates = [
    process.env.OTTOD_PATH,
    path.join(process.resourcesPath || '', 'bin', name),
    path.join(__dirname, '..', 'bin', `${process.platform}-${process.arch}`, name),
    path.join(__dirname, '..', '..', '..', '.build', 'debug', name),
  ].filter(Boolean);
  return candidates.find((candidate) => fs.existsSync(candidate)) || null;
}

function send(channel, payload) {
  if (window && !window.isDestroyed()) window.webContents.send(channel, payload);
}

async function startDaemon() {
  if (client) client.dispose();
  client = null;
  const binary = ottodBinary();
  if (!binary) throw new Error('The Otto engine (ottod) is missing from this install.');
  if (!settings.workspace) return null;
  const next = new OttodClient({
    binary,
    stateDirectory: path.join(app.getPath('userData'), 'ottod'),
    workspaces: [settings.workspace],
    env,
  });
  next.on('event', (event) => send('ottod:event', event));
  next.on('log', (text) => console.error('[ottod]', text.trim()));
  next.on('exit', (status) => {
    if (client === next) send('ottod:exit', status);
  });
  const hello = await next.start();
  client = next;
  return hello;
}

/** Windows batch shims (npm installs `claude.cmd`) cannot be started directly in a console. */
function launchCommand(executable, args) {
  if (isWindows && /\.(cmd|bat)$/i.test(executable)) {
    const cmd = path.join(env.SystemRoot || 'C:\\Windows', 'System32', 'cmd.exe');
    return { executable: cmd, args: ['/d', '/s', '/c', executable, ...args] };
  }
  return { executable, args };
}

function state(hello) {
  return {
    platform: process.platform,
    workspace: settings.workspace,
    workspaceName: settings.workspace ? path.basename(settings.workspace) : null,
    agents: discoverAgents(env).map(({ id, name, blurb, available }) => ({ id, name, blurb, available })),
    daemon: hello ? { version: hello.daemonVersion, protocol: hello.protocolVersion } : null,
  };
}

function registerIPC() {
  ipcMain.handle('app:state', async () => {
    let hello = null;
    if (settings.workspace && !client) hello = await startDaemon();
    else if (client) hello = await client.request('hello', { afterSequence: 0, limit: 1 });
    return state(hello);
  });

  ipcMain.handle('workspace:choose', async () => {
    const result = await dialog.showOpenDialog(window, {
      title: 'Choose a workspace folder',
      defaultPath: settings.workspace || os.homedir(),
      properties: ['openDirectory', 'createDirectory'],
    });
    if (result.canceled || !result.filePaths[0]) return state(null);
    settings.workspace = result.filePaths[0];
    saveSettings();
    return state(await startDaemon());
  });

  ipcMain.handle('session:launch', async (_event, { agentID, columns, rows }) => {
    if (!client) throw new Error('Choose a workspace first.');
    const agent = discoverAgents(env).find((candidate) => candidate.id === agentID);
    if (!agent || !agent.executable) throw new Error(`${agent ? agent.name : agentID} is not installed.`);
    const command = launchCommand(agent.executable, []);
    const { sessionID } = await client.launch({ ...command, workspace: settings.workspace, columns, rows });
    return { sessionID, agentID: agent.id, name: agent.name };
  });

  ipcMain.handle('session:input', (_event, { sessionID, text }) => client?.input(sessionID, text));
  ipcMain.handle('session:resize', (_event, { sessionID, columns, rows }) => client?.resize(sessionID, columns, rows));
  ipcMain.handle('session:stop', (_event, { sessionID }) => client?.stop(sessionID));
  ipcMain.handle('link:open', (_event, url) => {
    if (/^https?:\/\//.test(url)) shell.openExternal(url);
  });
}

function createWindow() {
  window = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 820,
    minHeight: 520,
    backgroundColor: '#101113',
    title: 'Otto',
    icon: path.join(__dirname, '..', 'build', 'icon.png'),
    autoHideMenuBar: true,
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  window.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
}

app.whenReady().then(() => {
  env = loginEnvironment();
  settings = loadSettings();
  if (process.env.OTTO_DESKTOP_WORKSPACE) settings.workspace = process.env.OTTO_DESKTOP_WORKSPACE;
  registerIPC();
  createWindow();
});

app.on('window-all-closed', () => {
  client?.dispose();
  app.quit();
});
