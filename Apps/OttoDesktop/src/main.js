'use strict';

const { app, BrowserWindow, dialog, ipcMain, shell } = require('electron');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { OttodClient } = require('./ottod');
const { EngineClient } = require('./engine');
const { loginEnvironment, discoverAgents } = require('./agents');

const isWindows = process.platform === 'win32';
let window = null;
let terminals = null; // ottod: raw terminal sessions
let engine = null; // otto-engine: bots, threads, runs and approvals
let engineError = null;
let env = null;
let settings = null;

// Never share a data folder with the native Otto app (macOS uses "Application Support/Otto").
app.setPath('userData', path.join(app.getPath('appData'), 'Otto Desktop'));

/** The engine RPC methods the window may call; everything else stays in this process. */
const ENGINE_METHODS = new Set([
  'bot.list',
  'bot.create',
  'thread.list',
  'thread.start',
  'thread.getSnapshot',
  'thread.events',
  'message.send',
  'run.interrupt',
  'run.stop',
  'approval.get',
  'approval.respond',
]);

/** Owner-only desktop methods (otto-engine DesktopAPI) the window may call. */
const DESKTOP_METHODS = new Set([
  'home.snapshot',
  'brief.addTodo',
  'brief.complete',
  'brief.dismiss',
  'review.approve',
  'review.reject',
  'review.comment',
  'documents.list',
  'documents.create',
  'documents.read',
  'documents.saveText',
  'memory.snapshot',
  'memory.addPersonal',
  'memory.removePersonal',
  'memory.removeOperating',
  'dashboards.snapshot',
  'dashboards.create',
  'dashboards.rename',
  'dashboards.delete',
  'dashboards.setLook',
  'cards.add',
  'cards.setLook',
  'cards.move',
  'cards.remove',
  'automations.list',
  'automations.create',
  'automations.setEnabled',
  'automations.runNow',
  'automations.delete',
  'activity.snapshot',
  'files.list',
  'files.read',
  'files.save',
  'appearance.get',
  'appearance.set',
]);

/** Desktop agent IDs to the engine's provider names. */
const PROVIDERS = { claude: 'Claude Code', codex: 'Codex', pi: 'Pi' };

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

/** Packaged builds ship binaries in resources/bin; development uses env overrides or SwiftPM. */
function binary(name, override) {
  const file = isWindows ? `${name}.exe` : name;
  const candidates = [
    override,
    path.join(process.resourcesPath || '', 'bin', file),
    path.join(__dirname, '..', 'bin', `${process.platform}-${process.arch}`, file),
    path.join(__dirname, '..', '..', '..', '.build', 'debug', file),
  ].filter(Boolean);
  return candidates.find((candidate) => fs.existsSync(candidate)) || null;
}

function send(channel, payload) {
  if (window && !window.isDestroyed()) window.webContents.send(channel, payload);
}

async function startTerminals() {
  terminals?.dispose();
  terminals = null;
  const ottod = binary('ottod', process.env.OTTOD_PATH);
  if (!ottod) throw new Error('The Otto engine (ottod) is missing from this install.');
  const next = new OttodClient({
    binary: ottod,
    stateDirectory: path.join(app.getPath('userData'), 'ottod'),
    workspaces: [settings.workspace],
    env,
  });
  next.on('event', (event) => send('ottod:event', event));
  next.on('log', (text) => console.error('[ottod]', text.trim()));
  next.on('exit', (status) => {
    if (terminals === next) send('ottod:exit', status);
  });
  const hello = await next.start();
  terminals = next;
  return hello;
}

/** One engine per workspace, with its state kept beside the desktop app's own data. */
async function startEngine() {
  engine?.dispose();
  engine = null;
  engineError = null;
  const ottoEngine = binary('otto-engine', process.env.OTTO_ENGINE_PATH);
  if (!ottoEngine) {
    engineError = 'Chats are not available in this build yet. Terminals work as usual.';
    return null;
  }
  const key = crypto.createHash('sha256').update(settings.workspace).digest('hex').slice(0, 16);
  const next = new EngineClient({
    binary: ottoEngine,
    stateDirectory: path.join(app.getPath('userData'), 'engines', key),
    workspace: settings.workspace,
    env,
  });
  next.on('log', (text) => console.error('[otto-engine]', text.trim()));
  next.on('exit', (status) => {
    if (engine === next) send('engine:exit', status);
  });
  try {
    const capabilities = await next.start();
    engine = next;
    return capabilities;
  } catch (error) {
    next.dispose();
    engineError = `The chat engine could not start: ${error.message}`;
    return null;
  }
}

/** Terminals and chats start independently: either one missing must not take down the other. */
async function startWorkspace() {
  if (!settings.workspace) return { hello: null };
  const [terminalResult] = await Promise.allSettled([startTerminals(), startEngine()]);
  if (terminalResult.status === 'rejected') {
    console.error('[ottod]', terminalResult.reason?.message ?? terminalResult.reason);
    return { hello: null };
  }
  return { hello: terminalResult.value };
}

/** Windows batch shims (npm installs `claude.cmd`) cannot be started directly in a console. */
function launchCommand(executable, args) {
  if (isWindows && /\.(cmd|bat)$/i.test(executable)) {
    const cmd = path.join(env.SystemRoot || 'C:\\Windows', 'System32', 'cmd.exe');
    return { executable: cmd, args: ['/d', '/s', '/c', executable, ...args] };
  }
  return { executable, args };
}

function firstName() {
  let name = '';
  try {
    if (process.platform === 'darwin') {
      name = require('node:child_process').execFileSync('id', ['-F'], { encoding: 'utf8' }).trim();
    }
  } catch {}
  if (!name) name = os.userInfo().username || '';
  const first = name.split(/[\s._-]+/)[0] || '';
  return first ? first[0].toUpperCase() + first.slice(1) : '';
}

function state(hello) {
  const agents = discoverAgents(env);
  return {
    platform: process.platform,
    workspace: settings.workspace,
    workspaceName: settings.workspace ? path.basename(settings.workspace) : null,
    agents: agents.map(({ id, name, blurb, available, executable, install, login }) => ({
      id,
      name,
      blurb,
      available,
      path: executable,
      install,
      canSignIn: Array.isArray(login),
    })),
    version: app.getVersion(),
    // Greetings use the first name, as the Mac app does with the account's full name.
    userName: firstName(),
    providers: agents
      .filter((agent) => PROVIDERS[agent.id])
      .map((agent) => ({ id: PROVIDERS[agent.id], name: agent.name, available: agent.available })),
    daemon: hello ? { version: hello.daemonVersion, protocol: hello.protocolVersion } : null,
    chat: { available: Boolean(engine), error: engineError },
  };
}

function registerIPC() {
  ipcMain.handle('app:state', async () => {
    let hello = null;
    if (settings.workspace && !terminals && !engine) hello = (await startWorkspace()).hello;
    else if (terminals) hello = await terminals.request('hello', { afterSequence: 0, limit: 1 });
    return state(hello);
  });

  ipcMain.handle('workspace:choose', async () => {
    const result = await dialog.showOpenDialog(window, {
      title: 'Choose a workspace folder',
      defaultPath: settings.workspace || os.homedir(),
      properties: ['openDirectory', 'createDirectory'],
    });
    if (result.canceled || !result.filePaths[0]) return state(null);
    settings.workspace = fs.realpathSync(result.filePaths[0]);
    saveSettings();
    return state((await startWorkspace()).hello);
  });

  ipcMain.handle('engine:call', async (_event, { method, parameters }) => {
    if (!ENGINE_METHODS.has(method)) throw new Error(`Not allowed: ${method}`);
    if (!engine) throw new Error(engineError || 'Choose a workspace first.');
    return engine.call(method, parameters);
  });

  ipcMain.handle('engine:desktop', async (_event, { method, params }) => {
    if (!DESKTOP_METHODS.has(method)) throw new Error(`Not allowed: ${method}`);
    if (!engine) throw new Error(engineError || 'Choose a workspace first.');
    return engine.desktop(method, params);
  });

  // `signIn` runs only the agent's own fixed login arguments, never anything from the window.
  ipcMain.handle('session:launch', async (_event, { agentID, columns, rows, signIn }) => {
    if (!terminals) throw new Error('Choose a workspace first.');
    const agent = discoverAgents(env).find((candidate) => candidate.id === agentID);
    if (!agent || !agent.executable) throw new Error(`${agent ? agent.name : agentID} is not installed.`);
    const args = signIn && Array.isArray(agent.login) ? agent.login : [];
    const command = launchCommand(agent.executable, args);
    const { sessionID } = await terminals.launch({ ...command, workspace: settings.workspace, columns, rows });
    return { sessionID, agentID: agent.id, name: signIn ? `${agent.name} sign-in` : agent.name };
  });

  ipcMain.handle('session:input', (_event, { sessionID, text }) => terminals?.input(sessionID, text));
  ipcMain.handle('session:resize', (_event, { sessionID, columns, rows }) =>
    terminals?.resize(sessionID, columns, rows),
  );
  ipcMain.handle('session:stop', (_event, { sessionID }) => terminals?.stop(sessionID));
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
  // Agents record sessions under the resolved folder; resolve once so every path agrees.
  if (settings.workspace) {
    try {
      settings.workspace = fs.realpathSync(settings.workspace);
    } catch {}
  }
  registerIPC();
  createWindow();
});

app.on('window-all-closed', () => {
  terminals?.dispose();
  engine?.dispose();
  app.quit();
});
