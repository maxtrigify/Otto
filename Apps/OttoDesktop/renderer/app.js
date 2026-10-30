'use strict';

const $ = (id) => document.getElementById(id);
const sessions = new Map(); // sessionID -> { name, agentID, term, fit, element, status, startedAt }
const pendingEvents = new Map(); // events that raced ahead of the launch response
let activeID = null;
let appState = null;

const theme = {
  background: '#0d0e10',
  foreground: '#e7e5e0',
  cursor: '#f2c879',
  cursorAccent: '#0d0e10',
  selectionBackground: '#f2c87944',
  black: '#1b1d21', brightBlack: '#5c6068',
  red: '#ec7b74', brightRed: '#f59b95',
  green: '#9fcf8a', brightGreen: '#b9e3a6',
  yellow: '#f2c879', brightYellow: '#f8dba3',
  blue: '#7fa8e8', brightBlue: '#a3c2f1',
  magenta: '#c49be8', brightMagenta: '#d8b9f2',
  cyan: '#78c9c4', brightCyan: '#9ddcd8',
  white: '#d8d6d0', brightWhite: '#ffffff',
};

function toast(message) {
  const element = $('toast');
  element.textContent = message;
  element.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (element.hidden = true), 4200);
}

function decode(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function relativeTime(date) {
  const seconds = Math.round((Date.now() - date) / 1000);
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return `${Math.round(seconds / 60)}m ago`;
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

// ---- Rendering -------------------------------------------------------------------------

function renderWorkspace() {
  $('workspace-name').textContent = appState?.workspaceName || 'Choose a folder';
  $('workspace-button').title = appState?.workspace || 'Choose a workspace folder';
  const engine = appState?.daemon;
  $('engine-status').textContent = engine
    ? `Engine ${engine.version} · ${appState.platform}`
    : appState?.workspace ? 'Engine offline' : 'Choose a workspace to start';
  $('engine-status').classList.toggle('offline', !engine);
}

function renderAgents() {
  const container = $('agents');
  container.replaceChildren();
  const hasWorkspace = Boolean(appState?.workspace);
  $('choose-workspace').hidden = hasWorkspace;
  $('welcome-title').textContent = hasWorkspace ? 'What should we work on?' : 'Welcome to Otto';
  $('welcome-sub').textContent = hasWorkspace
    ? `Start a chat with an agent in ${appState.workspaceName}.`
    : 'Pick the folder your agents should work in. You can change it any time.';
  if (!hasWorkspace) return;
  for (const agent of appState.agents) {
    const button = document.createElement('button');
    button.className = 'agent-card';
    button.disabled = !agent.available;
    button.innerHTML = `<span class="agent-name"></span><span class="agent-blurb"></span>`;
    button.querySelector('.agent-name').textContent = agent.name;
    button.querySelector('.agent-blurb').textContent = agent.available ? agent.blurb : 'Not installed';
    button.addEventListener('click', () => launch(agent.id));
    container.append(button);
  }
}

function renderSessions() {
  const list = $('sessions');
  list.replaceChildren();
  const ordered = [...sessions.entries()].sort((a, b) => b[1].startedAt - a[1].startedAt);
  if (!ordered.length) {
    const empty = document.createElement('li');
    empty.className = 'sessions-empty';
    empty.textContent = 'No chats yet';
    list.append(empty);
  }
  for (const [id, session] of ordered) {
    const item = document.createElement('li');
    const button = document.createElement('button');
    button.className = 'session' + (id === activeID ? ' active' : '');
    button.innerHTML = `<span class="dot ${session.status}"></span><span class="session-name"></span><span class="session-time"></span>`;
    button.querySelector('.session-name').textContent = session.name;
    button.querySelector('.session-time').textContent = relativeTime(session.startedAt);
    button.addEventListener('click', () => activate(id));
    item.append(button);
    list.append(item);
  }
}

function renderStage() {
  const session = activeID ? sessions.get(activeID) : null;
  $('welcome').hidden = Boolean(session);
  $('terminals').hidden = !session;
  $('stage-header').hidden = !session;
  if (!session) return;
  $('stage-name').textContent = session.name;
  $('stage-dot').className = `dot ${session.status}`;
  $('stage-meta').textContent =
    session.status === 'running' ? appState?.workspaceName || '' : session.exitText || 'Ended';
  $('stop-button').hidden = session.status !== 'running';
  for (const [id, other] of sessions) other.element.hidden = id !== activeID;
  requestAnimationFrame(() => {
    session.fit.fit();
    session.term.focus();
  });
}

function render() {
  renderWorkspace();
  renderAgents();
  renderSessions();
  renderStage();
}

// ---- Sessions --------------------------------------------------------------------------

function createTerminal() {
  const element = document.createElement('div');
  element.className = 'terminal-host';
  $('terminals').append(element);
  const term = new Terminal({
    theme,
    fontFamily: '"Cascadia Code", "SF Mono", Menlo, Consolas, "DejaVu Sans Mono", monospace',
    fontSize: 13,
    lineHeight: 1.2,
    cursorBlink: true,
    scrollback: 10000,
    allowProposedApi: false,
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(element);
  return { term, fit, element };
}

async function launch(agentID) {
  const view = createTerminal();
  $('welcome').hidden = true;
  $('terminals').hidden = false;
  view.fit.fit();
  try {
    const result = await window.otto.launch(agentID, view.term.cols || 120, view.term.rows || 36);
    const session = { ...view, name: result.name, agentID, status: 'running', startedAt: new Date() };
    sessions.set(result.sessionID, session);
    view.term.onData((text) => {
      if (session.status === 'running') window.otto.input(result.sessionID, text).catch(() => {});
    });
    view.term.onResize(({ cols, rows }) => {
      if (session.status === 'running') window.otto.resize(result.sessionID, cols, rows).catch(() => {});
    });
    activate(result.sessionID);
    const early = pendingEvents.get(result.sessionID) || [];
    pendingEvents.delete(result.sessionID);
    early.forEach(handleEvent);
  } catch (error) {
    view.term.dispose();
    view.element.remove();
    toast(error.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, ''));
    renderStage();
  }
}

function activate(sessionID) {
  activeID = sessionID;
  renderSessions();
  renderStage();
}

function handleEvent(event) {
  const session = sessions.get(event.sessionID);
  if (!session) {
    if (event.sessionID) pendingEvents.set(event.sessionID, [...(pendingEvents.get(event.sessionID) || []), event]);
    return;
  }
  if (event.kind === 'session.output') {
    session.term.write(decode(event.payload.data));
    return;
  }
  if (event.kind === 'session.exited' || event.kind === 'session.stopped') {
    if (session.status !== 'running') return;
    session.status = 'ended';
    const code = event.payload?.exitCode;
    session.exitText = event.kind === 'session.stopped' ? 'Stopped' : code === 0 ? 'Finished' : `Exited (${code})`;
    session.term.write(`\r\n\x1b[2m— ${session.exitText} —\x1b[0m\r\n`);
    renderSessions();
    if (event.sessionID === activeID) renderStage();
  }
}

// ---- Wiring ----------------------------------------------------------------------------

$('new-chat').addEventListener('click', () => {
  activeID = null;
  renderSessions();
  renderStage();
});
$('workspace-button').addEventListener('click', chooseWorkspace);
$('choose-workspace').addEventListener('click', chooseWorkspace);
$('stop-button').addEventListener('click', () => {
  if (activeID) window.otto.stop(activeID).catch((error) => toast(error.message));
});
window.addEventListener('resize', () => {
  const session = activeID && sessions.get(activeID);
  if (session) session.fit.fit();
});
setInterval(renderSessions, 30_000);

async function chooseWorkspace() {
  try {
    const next = await window.otto.chooseWorkspace();
    if (next.workspace !== appState?.workspace) {
      for (const session of sessions.values()) {
        session.term.dispose();
        session.element.remove();
      }
      sessions.clear();
      activeID = null;
    }
    appState = next;
    render();
  } catch (error) {
    toast(error.message);
  }
}

window.otto.onEvent(handleEvent);
window.otto.onExit(() => {
  if (appState) appState.daemon = null;
  for (const session of sessions.values()) session.status = 'ended';
  render();
  toast('The Otto engine stopped. Change workspace or restart Otto to reconnect.');
});

window.otto
  .state()
  .then((state) => {
    appState = state;
    render();
  })
  .catch((error) => {
    appState = { agents: [], workspace: null };
    render();
    $('engine-status').textContent = 'Engine unavailable';
    toast(error.message);
  });
