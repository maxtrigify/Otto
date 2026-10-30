'use strict';

const $ = (id) => document.getElementById(id);
let appState = null;
let bots = [];
let threads = [];
/** { type: 'welcome' } | { type: 'chat', threadID, bot } | { type: 'terminal', sessionID } */
let view = { type: 'welcome' };
/** The open chat: transcript, event cursor, run and pending approval. */
let chat = null;
let pollTimer = null;

const STATE_LABELS = {
  idle: '',
  working: 'Working…',
  waiting_for_user: 'Waiting for you',
  approval_required: 'Needs approval',
  failed: 'Failed',
  done: '',
  // Bots end their process after every reply; only a Stop the user pressed is worth saying.
  stopped: '',
  host_offline: 'Engine offline',
};

function toast(message) {
  const element = $('toast');
  element.textContent = message;
  element.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (element.hidden = true), 4200);
}

const cleanError = (error) =>
  String(error?.message || error).replace(/^Error invoking remote method '[^']+': (Error: )?/, '');

function relativeTime(value) {
  const date = new Date(value);
  const seconds = Math.round((Date.now() - date) / 1000);
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return `${Math.round(seconds / 60)}m ago`;
  if (seconds < 86400) return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  return date.toLocaleDateString([], { day: 'numeric', month: 'short' });
}

function dotClass(state) {
  if (state === 'working') return 'running';
  if (state === 'approval_required' || state === 'waiting_for_user') return 'attention';
  if (state === 'failed') return 'failed';
  return 'idle';
}

const chatAvailable = () => Boolean(appState?.chat?.available);

// ---- Engine data ---------------------------------------------------------------------------

async function refreshRoster() {
  if (!chatAvailable()) {
    bots = [];
    threads = [];
    return;
  }
  try {
    const [roster, list] = await Promise.all([
      window.otto.engine('bot.list'),
      window.otto.engine('thread.list'),
    ]);
    bots = roster.bots;
    threads = list.threads;
  } catch (error) {
    console.error(error);
  }
}

// ---- Sidebar -------------------------------------------------------------------------------

function sessionButton({ active, dot, name, time, onClick }) {
  const item = document.createElement('li');
  const button = document.createElement('button');
  button.className = 'session' + (active ? ' active' : '');
  button.innerHTML = '<span class="dot"></span><span class="session-name"></span><span class="session-time"></span>';
  button.querySelector('.dot').className = `dot ${dot}`;
  button.querySelector('.session-name').textContent = name;
  button.querySelector('.session-time').textContent = time;
  button.addEventListener('click', onClick);
  item.append(button);
  return item;
}

function renderSidebar() {
  $('workspace-name').textContent = appState?.workspaceName || 'Choose a folder';
  $('workspace-button').title = appState?.workspace || 'Choose a workspace folder';
  const engine = appState?.daemon;
  $('engine-status').textContent = engine
    ? `Engine ${engine.version} · ${appState.platform}${chatAvailable() ? '' : ' · terminals only'}`
    : appState?.workspace ? 'Engine offline' : 'Choose a workspace to start';
  $('engine-status').classList.toggle('offline', !engine);

  const threadList = $('threads');
  threadList.replaceChildren();
  if (!threads.length) {
    const empty = document.createElement('li');
    empty.className = 'sessions-empty';
    empty.textContent = chatAvailable() ? 'No chats yet' : 'Not available here yet';
    threadList.append(empty);
  }
  for (const thread of threads) {
    threadList.append(
      sessionButton({
        active: view.type === 'chat' && view.threadID === thread.id,
        dot: dotClass(thread.state),
        name: thread.title,
        time: relativeTime(thread.updatedAt),
        onClick: () => openThread(thread.id),
      }),
    );
  }

  const terminalList = $('terminals-list');
  terminalList.replaceChildren();
  const sessions = [...Terminals.sessions.entries()].sort((a, b) => b[1].startedAt - a[1].startedAt);
  for (const [id, session] of sessions) {
    terminalList.append(
      sessionButton({
        active: view.type === 'terminal' && view.sessionID === id,
        dot: session.status === 'running' ? 'running' : 'idle',
        name: session.name,
        time: relativeTime(session.startedAt),
        onClick: () => showTerminal(id),
      }),
    );
  }
}

// ---- Views ---------------------------------------------------------------------------------

function showView(type) {
  $('welcome').hidden = type !== 'welcome';
  $('chat').hidden = type !== 'chat';
  $('terminal-view').hidden = type !== 'terminal';
}

function renderWelcome() {
  const hasWorkspace = Boolean(appState?.workspace);
  $('choose-workspace').hidden = hasWorkspace;
  $('welcome-title').textContent = hasWorkspace ? 'What should we work on?' : 'Welcome to Otto';
  $('welcome-sub').textContent = !hasWorkspace
    ? 'Pick the folder your bots and agents work in. You can change it any time.'
    : chatAvailable()
      ? `Chat with a bot in ${appState.workspaceName}, or open a terminal.`
      : `Open an agent in a terminal in ${appState.workspaceName}.`;

  const container = $('bots');
  container.replaceChildren();
  $('chat-note').hidden = !hasWorkspace || chatAvailable();
  $('chat-note').textContent = appState?.chat?.error || '';
  if (hasWorkspace && chatAvailable()) {
    for (const bot of bots) {
      const card = document.createElement('button');
      card.className = 'agent-card';
      card.innerHTML = '<span class="agent-name"></span><span class="agent-blurb"></span>';
      card.querySelector('.agent-name').textContent = bot.name;
      card.querySelector('.agent-blurb').textContent = bot.jobTitle || bot.provider;
      card.addEventListener('click', () => openBot(bot));
      container.append(card);
    }
    const create = document.createElement('button');
    create.className = 'agent-card new-bot';
    create.innerHTML = '<span class="agent-name">+ New bot</span><span class="agent-blurb">Give it a job</span>';
    create.addEventListener('click', openBotDialog);
    container.append(create);
  }

  const row = $('terminal-row');
  row.replaceChildren();
  if (!hasWorkspace) return;
  const label = document.createElement('span');
  label.className = 'terminal-row-label';
  label.textContent = 'Or open in a terminal:';
  row.append(label);
  for (const agent of appState.agents) {
    const button = document.createElement('button');
    button.className = 'chip';
    button.disabled = !agent.available;
    button.textContent = agent.available ? agent.name : `${agent.name} (not installed)`;
    button.addEventListener('click', () => openTerminal(agent.id));
    row.append(button);
  }
}

function goHome() {
  stopPolling();
  chat = null;
  view = { type: 'welcome' };
  showView('welcome');
  renderWelcome();
  renderSidebar();
}

// ---- Chats ---------------------------------------------------------------------------------

function newChatState(threadID, bot) {
  return { threadID, bot, messages: [], cursor: 0, state: 'idle', activeRunID: null, approval: null, sending: false };
}

function openBot(bot) {
  const existing = threads.find((thread) => thread.kind === 'bot' && thread.botProfileIDs.includes(bot.id));
  if (existing) return openThread(existing.id);
  stopPolling();
  chat = newChatState(null, bot);
  view = { type: 'chat', threadID: null, bot };
  showView('chat');
  renderChat();
  renderSidebar();
  $('composer-input').focus();
}

async function openThread(threadID) {
  stopPolling();
  try {
    const snapshot = await window.otto.engine('thread.getSnapshot', { threadID });
    const bot = bots.find((candidate) => snapshot.thread.botProfileIDs.includes(candidate.id)) || null;
    chat = newChatState(threadID, bot);
    chat.title = snapshot.thread.title;
    chat.messages = snapshot.messages;
    chat.cursor = snapshot.lastEventSequence;
    chat.state = snapshot.thread.state;
    chat.activeRunID = snapshot.activeRunID ?? null;
    view = { type: 'chat', threadID, bot };
    showView('chat');
    if (chat.state === 'approval_required') await loadApproval();
    renderChat(true);
    renderSidebar();
    startPolling();
    $('composer-input').focus();
  } catch (error) {
    toast(cleanError(error));
  }
}

function upsertMessage(message) {
  const index = chat.messages.findIndex((existing) => existing.id === message.id);
  if (index >= 0) chat.messages[index] = message;
  else chat.messages.push(message);
}

async function applyEvents(page) {
  let changed = false;
  let needsApproval = false;
  for (const event of page.events) {
    chat.cursor = Math.max(chat.cursor, event.sequence);
    const content = event.content || {};
    if (content.message) {
      upsertMessage(content.message);
      changed = true;
    }
    if (content.runID && (event.kind === 'run.started' || event.kind === 'run.state_changed')) {
      chat.activeRunID = content.runID;
    }
    if (content.state) {
      chat.state = content.state;
      changed = true;
    }
    if (event.kind === 'run.completed' || event.kind === 'run.failed') {
      chat.activeRunID = null;
      if (event.kind === 'run.failed' && content.detail) toast(content.detail);
    }
    if (event.kind === 'approval.requested') needsApproval = true;
  }
  if (needsApproval || (chat.state === 'approval_required' && !chat.approval)) await loadApproval();
  if (chat.state !== 'approval_required' && chat.approval) {
    chat.approval = null;
    changed = true;
  }
  return changed || needsApproval;
}

async function poll() {
  if (!chat?.threadID) return;
  const threadID = chat.threadID;
  try {
    const page = await window.otto.engine('thread.events', { threadID, afterSequence: chat.cursor, limit: 200 });
    if (chat?.threadID !== threadID) return;
    if (await applyEvents(page)) renderChat();
    if (page.hasMore) return poll();
  } catch (error) {
    console.error(error);
  }
}

function startPolling() {
  stopPolling();
  pollTimer = setInterval(poll, 450);
}

function stopPolling() {
  clearInterval(pollTimer);
  pollTimer = null;
}

async function loadApproval() {
  if (!chat?.threadID) return;
  try {
    chat.approval = await window.otto.engine('approval.get', { threadID: chat.threadID }).then((output) => output.request ?? null);
  } catch {
    chat.approval = null;
  }
}

function messageElement(message) {
  const element = document.createElement('div');
  element.className = `message ${message.role} ${message.kind}`;
  if (message.role === 'user') {
    element.textContent = message.text;
  } else if (message.kind === 'reasoning') {
    const details = document.createElement('details');
    const summary = document.createElement('summary');
    summary.textContent = 'Thinking';
    const body = document.createElement('div');
    body.className = 'reasoning-body';
    body.textContent = message.text;
    details.append(summary, body);
    element.append(details);
  } else if (message.kind === 'tool_call' || message.role === 'activity') {
    const details = document.createElement('details');
    const summary = document.createElement('summary');
    summary.textContent = message.text.split('\n')[0].slice(0, 140) || 'Tool';
    details.append(summary);
    if (message.detail || message.text.includes('\n')) {
      const pre = document.createElement('pre');
      pre.textContent = message.detail || message.text;
      details.append(pre);
    }
    element.append(details);
  } else if (message.kind === 'notice' || message.role === 'system') {
    element.textContent = message.text;
  } else {
    element.innerHTML = Markdown.render(message.text);
  }
  return element;
}

function renderChat(scrollToEnd = false) {
  if (!chat) return;
  const name = chat.bot?.name || chat.title || 'Chat';
  $('chat-name').textContent = name;
  $('chat-dot').className = `dot ${dotClass(chat.state)}`;
  $('chat-meta').textContent = STATE_LABELS[chat.state] ?? '';
  $('chat-stop').hidden = !(chat.state === 'working' && chat.activeRunID);
  $('composer-input').placeholder = `Message ${name}…`;

  const transcript = $('transcript');
  const nearBottom = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 80;
  transcript.replaceChildren();
  if (!chat.messages.length) {
    const empty = document.createElement('div');
    empty.className = 'transcript-empty';
    empty.textContent = chat.bot?.jobTitle ? `${name} · ${chat.bot.jobTitle}` : `Say hello to ${name}.`;
    transcript.append(empty);
  }
  for (const message of chat.messages) transcript.append(messageElement(message));
  if (chat.state === 'working') {
    const typing = document.createElement('div');
    typing.className = 'typing';
    typing.innerHTML = '<span></span><span></span><span></span>';
    transcript.append(typing);
  }
  if (scrollToEnd || nearBottom) transcript.scrollTop = transcript.scrollHeight;

  $('approval').hidden = !chat.approval;
  if (chat.approval) $('approval-reason').textContent = chat.approval.reason;
}

async function sendMessage(event) {
  event.preventDefault();
  const input = $('composer-input');
  const body = input.value.trim();
  if (!body || !chat || chat.sending) return;
  chat.sending = true;
  input.value = '';
  autosize();
  try {
    if (!chat.threadID) {
      const started = await window.otto.engine('thread.start', { botProfileID: chat.bot.id, initialMessage: body });
      await refreshRoster();
      await openThread(started.thread.id);
    } else {
      chat.state = 'working';
      renderChat(true);
      await window.otto.engine('message.send', {
        threadID: chat.threadID,
        clientMessageID: crypto.randomUUID().toUpperCase(),
        body,
      });
      await poll();
    }
  } catch (error) {
    input.value = body;
    toast(cleanError(error));
  } finally {
    if (chat) chat.sending = false;
  }
}

async function respond(decision) {
  if (!chat?.approval) return;
  const request = chat.approval;
  try {
    await window.otto.engine('approval.respond', {
      threadID: chat.threadID,
      requestID: request.requestID,
      nonce: request.nonce,
      decision,
    });
    chat.approval = null;
    renderChat();
  } catch (error) {
    toast(cleanError(error));
  }
}

function autosize() {
  const input = $('composer-input');
  input.style.height = 'auto';
  input.style.height = `${Math.min(input.scrollHeight, 220)}px`;
}

// ---- Bots ----------------------------------------------------------------------------------

function openBotDialog() {
  const select = $('bot-provider');
  select.replaceChildren();
  for (const provider of appState.providers) {
    const option = document.createElement('option');
    option.value = provider.id;
    option.textContent = provider.available ? provider.name : `${provider.name} (not installed)`;
    option.disabled = !provider.available;
    select.append(option);
  }
  const firstAvailable = appState.providers.find((provider) => provider.available);
  if (firstAvailable) select.value = firstAvailable.id;
  $('bot-name').value = '';
  $('bot-job').value = '';
  $('bot-dialog').showModal();
  $('bot-name').focus();
}

async function createBot(event) {
  if (event.submitter?.value !== 'create') return;
  event.preventDefault();
  const name = $('bot-name').value.trim();
  const responsibility = $('bot-job').value.trim();
  const provider = $('bot-provider').value;
  if (!name || !responsibility || !provider) return;
  try {
    const bot = await window.otto.engine('bot.create', { name, responsibility, provider });
    $('bot-dialog').close();
    await refreshRoster();
    openBot(bot);
  } catch (error) {
    toast(cleanError(error));
  }
}

// ---- Terminals -----------------------------------------------------------------------------

async function openTerminal(agentID) {
  stopPolling();
  chat = null;
  showView('terminal');
  try {
    const sessionID = await Terminals.launch(agentID);
    showTerminal(sessionID);
  } catch (error) {
    toast(cleanError(error));
    goHome();
  }
}

function showTerminal(sessionID) {
  stopPolling();
  chat = null;
  view = { type: 'terminal', sessionID };
  showView('terminal');
  Terminals.show(sessionID);
  renderSidebar();
}

Terminals.onChange = () => {
  renderSidebar();
  if (view.type === 'terminal') Terminals.show(view.sessionID);
};

// ---- Wiring --------------------------------------------------------------------------------

async function chooseWorkspace() {
  try {
    const next = await window.otto.chooseWorkspace();
    if (next.workspace !== appState?.workspace) Terminals.clear();
    appState = next;
    await refreshRoster();
    goHome();
  } catch (error) {
    toast(cleanError(error));
  }
}

$('new-chat').addEventListener('click', goHome);
$('new-terminal').addEventListener('click', () => {
  const agent = appState?.agents.find((candidate) => candidate.id === 'shell' && candidate.available);
  if (agent) openTerminal(agent.id);
});
$('workspace-button').addEventListener('click', chooseWorkspace);
$('choose-workspace').addEventListener('click', chooseWorkspace);
$('composer').addEventListener('submit', sendMessage);
$('composer-input').addEventListener('input', autosize);
$('composer-input').addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    $('composer').requestSubmit();
  }
});
$('chat-stop').addEventListener('click', async () => {
  if (!chat?.threadID || !chat.activeRunID) return;
  try {
    await window.otto.engine('run.stop', { threadID: chat.threadID, runID: chat.activeRunID });
    toast('Stopped');
  } catch (error) {
    toast(cleanError(error));
  }
});
$('approval-approve').addEventListener('click', () => respond('approve_once'));
$('approval-deny').addEventListener('click', () => respond('deny'));
$('bot-form').addEventListener('submit', createBot);
$('stop-button').addEventListener('click', () => {
  if (view.type === 'terminal') window.otto.stop(view.sessionID).catch((error) => toast(cleanError(error)));
});
$('transcript').addEventListener('click', (event) => {
  const link = event.target.closest('a[data-external]');
  if (!link) return;
  event.preventDefault();
  window.otto.openLink(link.href);
});
window.addEventListener('resize', () => {
  if (view.type === 'terminal') Terminals.fitActive(view.sessionID);
});
setInterval(async () => {
  await refreshRoster();
  renderSidebar();
  if (view.type === 'welcome') renderWelcome();
}, 4000);

window.otto.onEvent((event) => Terminals.handleEvent(event));
window.otto.onExit(() => {
  if (appState) appState.daemon = null;
  Terminals.endAll();
  renderSidebar();
  toast('The terminal engine stopped. Change workspace or restart Otto to reconnect.');
});
window.otto.onEngineExit(() => {
  if (appState) appState.chat = { available: false, error: 'The chat engine stopped. Restart Otto to reconnect.' };
  toast('The chat engine stopped. Restart Otto to reconnect.');
  goHome();
});

window.otto
  .state()
  .then(async (state) => {
    appState = state;
    await refreshRoster();
    goHome();
  })
  .catch((error) => {
    appState = { agents: [], providers: [], workspace: null, chat: { available: false } };
    goHome();
    $('engine-status').textContent = 'Engine unavailable';
    toast(cleanError(error));
  });
