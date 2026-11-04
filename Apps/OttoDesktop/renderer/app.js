'use strict';

const $ = (id) => document.getElementById(id);
let appState = null;
let bots = [];
let threads = [];
let teams = [];
/** 'home' | 'chat' — the window chrome's Home | Chat switch. */
let surface = 'home';
/** Inside Chat: { type: 'welcome' | 'chat' | 'documents' | 'editor' | 'memory' | 'settings' | 'terminal', ... } */
let view = { type: 'welcome' };
/** The open conversation: transcript, event cursor, run and pending approval. */
let chat = null;
let pollTimer = null;
let welcomeTarget = null;
let railQuery = '';

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

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
}

function toast(message) {
  const element = $('toast');
  element.textContent = message;
  element.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (element.hidden = true), 4200);
}

const cleanError = (error) =>
  String(error?.message || error).replace(/^Error invoking remote method '[^']+': (Error: )?/, '');

function dotClass(state) {
  if (state === 'working') return 'running';
  if (state === 'approval_required' || state === 'waiting_for_user') return 'attention';
  if (state === 'failed') return 'failed';
  return 'idle';
}

const chatAvailable = () => Boolean(appState?.chat?.available);
// A bot's own chat: its one-member channel (kind `bot_channel`), not a team room it joins.
const threadFor = (bot) =>
  threads.find((thread) => thread.kind !== 'group' && thread.botProfileIDs.length === 1 && thread.botProfileIDs[0] === bot.id);
const teamThread = (team) => threads.find((thread) => thread.kind === 'group' && thread.channelID === team.id);

// ---- Engine data ---------------------------------------------------------------------------

async function refreshRoster() {
  if (!chatAvailable()) {
    bots = [];
    threads = [];
    teams = [];
    return;
  }
  try {
    const [roster, list] = await Promise.all([window.otto.engine('bot.list'), window.otto.engine('thread.list')]);
    bots = roster.bots;
    teams = roster.teams ?? [];
    threads = list.threads;
  } catch (error) {
    console.error(error);
  }
}

// ---- Surfaces ------------------------------------------------------------------------------

function setSurface(next) {
  surface = next;
  $('home-surface').hidden = next !== 'home';
  $('chat-surface').hidden = next !== 'chat';
  $('surface-home').classList.toggle('active', next === 'home');
  $('surface-chat').classList.toggle('active', next === 'chat');
  if (next === 'home') {
    stopPolling();
    BrowserPlace.hide();
    Home.load();
  } else {
    renderSidebar();
    if (view.type === 'terminal') Terminals.fitActive(view.sessionID);
    if (view.type === 'browser') BrowserPlace.show();
  }
}

function showView(type) {
  // The browser page is a native view over the window; it must not linger over other places.
  if (type !== 'browser') BrowserPlace.hide();
  for (const [id, place] of [
    ['welcome', 'welcome'],
    ['chat', 'chat'],
    ['terminal-view', 'terminal'],
    ['documents', 'documents'],
    ['editor', 'editor'],
    ['memory', 'memory'],
    ['dashboards', 'dashboards'],
    ['browser', 'browser'],
    ['automations', 'automations'],
    ['activity', 'activity'],
    ['files', 'files'],
    ['note', 'note'],
    ['settings', 'settings'],
  ]) {
    $(id).hidden = type !== place;
  }
}

async function go(place) {
  if (surface !== 'chat') setSurface('chat');
  stopPolling();
  chat = null;
  await Documents.close();
  await Places.closeNote();
  if (place === 'terminal') {
    const shell = appState?.agents.find((agent) => agent.id === 'shell' && agent.available);
    if (shell) return openTerminal(shell.id);
    return;
  }
  if (place === 'welcome') return goWelcome();
  if (place !== 'settings' && !chatAvailable()) return goWelcome();
  view = { type: place };
  showView(place);
  renderSidebar();
  if (place === 'documents') await Documents.list();
  if (place === 'memory') await Memory.load();
  if (place === 'dashboards') await Dashboards.load();
  if (place === 'browser') await BrowserPlace.show();
  if (place === 'automations') await Places.loadAutomations();
  if (place === 'activity') await Places.loadActivity();
  if (place === 'files') await Places.loadFiles();
  if (place === 'settings') renderSettings();
}

// ---- Rail ----------------------------------------------------------------------------------

function railRow({ icon, face, label, active, count, dot, onClick, className = '' }) {
  const button = el('button', `rail-row ${className} ${active ? 'active' : ''}`.trim());
  if (face) button.append(Icons.face(face, 24));
  else if (icon) button.append(Icons.icon(icon, 15));
  button.append(el('span', 'rail-label', label));
  if (dot && dot !== 'idle') button.append(el('span', `dot ${dot}`));
  else if (count) button.append(el('span', 'count', String(count)));
  button.addEventListener('click', onClick);
  return button;
}

function renderSidebar() {
  const places = $('places');
  places.replaceChildren();
  if (chatAvailable()) {
    places.append(
      railRow({ icon: 'doc.richtext', label: 'Documents', active: ['documents', 'editor'].includes(view.type), onClick: () => go('documents') }),
      railRow({ icon: 'chart.bar', label: 'Dashboards', active: view.type === 'dashboards', onClick: () => go('dashboards') }),
      railRow({ icon: 'globe', label: 'Browser', active: view.type === 'browser', onClick: () => go('browser') }),
      railRow({ icon: 'clock', label: 'Automations', active: view.type === 'automations', onClick: () => go('automations') }),
      railRow({ icon: 'tray', label: 'Activity', active: view.type === 'activity', onClick: () => go('activity') }),
      railRow({ icon: 'doc.text', label: 'Files & notes', active: ['files', 'note'].includes(view.type), onClick: () => go('files') }),
      railRow({ icon: 'brain', label: 'Memory', active: view.type === 'memory', onClick: () => go('memory') }),
    );
  }

  const needle = railQuery.trim().toLowerCase();
  const matches = (text) => !needle || text.toLowerCase().includes(needle);
  // Teams sit above bots, as on the Mac; the group appears once a team is possible.
  const teamsList = $('teams-list');
  teamsList.replaceChildren();
  $('teams-header').hidden = !chatAvailable() || (!teams.length && bots.length < 2);
  for (const team of teams.filter((candidate) => matches(candidate.name))) {
    const thread = teamThread(team);
    teamsList.append(
      railRow({
        icon: 'person.2',
        label: team.name,
        className: 'team-row',
        active: view.type === 'chat' && chat?.teamID === team.id,
        dot: thread ? dotClass(thread.state) : null,
        onClick: () => openTeam(team),
      }),
    );
  }

  const botsList = $('bots-list');
  botsList.replaceChildren();
  const visibleBots = bots.filter((bot) => matches(`${bot.name} ${bot.jobTitle || ''}`));
  if (!bots.length) {
    const empty = el('div', 'rail-empty');
    empty.append(el('strong', '', chatAvailable() ? 'No bots yet' : 'Chats unavailable'));
    empty.append(el('span', '', chatAvailable() ? 'Hire a durable teammate. Its chat stays pinned here.' : appState?.chat?.error || ''));
    botsList.append(empty);
  }
  for (const bot of visibleBots) {
    const thread = threadFor(bot);
    botsList.append(
      railRow({
        face: bot.name,
        label: bot.name,
        className: 'bot-row',
        active: view.type === 'chat' && chat?.bot?.id === bot.id,
        dot: thread ? dotClass(thread.state) : null,
        onClick: () => openBot(bot),
      }),
    );
  }

  const sessionsList = $('sessions-list');
  sessionsList.replaceChildren();
  const sessions = [...Terminals.sessions.entries()]
    .filter(([, session]) => matches(session.name))
    .sort((a, b) => b[1].startedAt - a[1].startedAt);
  if (!sessions.length && !needle) {
    const empty = el('div', 'rail-empty');
    empty.append(el('strong', '', 'No sessions loaded'), el('span', '', 'One-off terminals with an agent land here. They are not hired bots.'));
    sessionsList.append(empty);
  }
  for (const [id, session] of sessions) {
    sessionsList.append(
      railRow({
        icon: 'terminal',
        label: session.name,
        active: view.type === 'terminal' && view.sessionID === id,
        dot: session.status === 'running' ? 'running' : null,
        onClick: () => showTerminal(id),
      }),
    );
  }

  $('nav-settings').classList.toggle('active', view.type === 'settings');
  const active = threads.filter((thread) => thread.state === 'working').length + [...Terminals.sessions.values()].filter((session) => session.status === 'running').length;
  const status = $('engine-status');
  status.textContent = appState?.workspace ? (appState?.daemon || chatAvailable() ? `${active} active` : 'offline') : 'no workspace';
  status.classList.toggle('offline', !(appState?.daemon || chatAvailable()));

  $('workspace-name').textContent = appState?.workspaceName || 'Choose a folder';
  $('activity-badge').hidden = !Home.reviewCount && !threads.some((thread) => thread.state === 'approval_required');
}

// ---- Chat welcome --------------------------------------------------------------------------

function goWelcome() {
  stopPolling();
  chat = null;
  view = { type: 'welcome' };
  showView('welcome');
  renderWelcome();
  renderSidebar();
}

function renderWelcome() {
  const hasWorkspace = Boolean(appState?.workspace);
  const hour = new Date().getHours();
  const part = hour < 5 ? 'Evening' : hour < 12 ? 'Morning' : hour < 18 ? 'Afternoon' : 'Evening';
  $('welcome-title').textContent = appState?.userName ? `${part}, ${appState.userName}.` : `${part}.`;
  $('welcome-sub').textContent = hasWorkspace ? 'What are we getting into?' : 'Pick the folder your bots and agents work in.';
  $('choose-workspace').hidden = hasWorkspace;
  $('chat-note').hidden = !hasWorkspace || chatAvailable();
  $('chat-note').textContent = appState?.chat?.error || '';
  $('welcome-composer').hidden = !hasWorkspace || !chatAvailable();

  if (!bots.some((bot) => bot.id === welcomeTarget)) welcomeTarget = bots[0]?.id ?? null;
  const target = bots.find((bot) => bot.id === welcomeTarget);
  $('welcome-input').placeholder = target ? `Message ${target.name}…` : 'Hire a bot to start a chat…';

  const suggestions = $('suggestions');
  suggestions.replaceChildren();
  if (hasWorkspace && chatAvailable()) {
    const ideas = ['Brief me on today', 'Draft a doc', 'Research a website', 'Plan my week'];
    ideas.forEach((idea, index) => {
      if (index) suggestions.append(el('span', 'sep', '·'));
      const button = el('button', '', idea);
      button.type = 'button';
      button.addEventListener('click', () => {
        $('welcome-input').value = idea;
        $('welcome-input').focus();
        $('welcome-send').classList.add('ready');
      });
      suggestions.append(button);
    });
  }

  const bring = $('bring-in');
  bring.replaceChildren();
  if (bots.length) {
    bring.append(el('span', 'label', 'Bring in'));
    for (const bot of bots.slice(0, 8)) {
      const button = el('button');
      button.type = 'button';
      button.title = bot.name;
      button.append(Icons.face(bot.name, 22));
      button.addEventListener('click', () => {
        welcomeTarget = bot.id;
        renderWelcome();
        $('welcome-input').focus();
      });
      bring.append(button);
    }
  }
}

// ---- Chats ---------------------------------------------------------------------------------

async function openTeam(team) {
  if (surface !== 'chat') setSurface('chat');
  let thread = teamThread(team);
  if (!thread) {
    await refreshRoster();
    thread = teamThread(team);
  }
  if (thread) await openThread(thread.id);
  else toast('That team’s room could not be found');
}

function newChatState(threadID, bot) {
  return { threadID, bot, messages: [], cursor: 0, state: 'idle', activeRunID: null, approval: null, sending: false };
}

function openBot(bot) {
  if (surface !== 'chat') setSurface('chat');
  const existing = threadFor(bot);
  if (existing) return openThread(existing.id);
  stopPolling();
  chat = newChatState(null, bot);
  view = { type: 'chat', threadID: null, bot };
  showView('chat');
  renderChat();
  renderSidebar();
  $('composer-input').focus();
}

/** Sends a message to a bot's chat without leaving the current page (Dashboards' prompt bar). */
async function askBot(botID, text) {
  const bot = bots.find((candidate) => candidate.id === botID);
  if (!bot) throw new Error('That bot is no longer here');
  const existing = threadFor(bot);
  if (existing) {
    await window.otto.engine('message.send', { threadID: existing.id, clientMessageID: crypto.randomUUID().toUpperCase(), body: text });
  } else {
    await window.otto.engine('thread.start', { botProfileID: bot.id, initialMessage: text });
    await refreshRoster();
  }
}

async function startChat(botID, text) {
  const bot = bots.find((candidate) => candidate.id === botID);
  if (!bot) return;
  try {
    const existing = threadFor(bot);
    if (existing) {
      await window.otto.engine('message.send', { threadID: existing.id, clientMessageID: crypto.randomUUID().toUpperCase(), body: text });
      setSurface('chat');
      await openThread(existing.id);
    } else {
      const started = await window.otto.engine('thread.start', { botProfileID: bot.id, initialMessage: text });
      await refreshRoster();
      setSurface('chat');
      await openThread(started.thread.id);
    }
  } catch (error) {
    toast(cleanError(error));
  }
}

async function openThread(threadID) {
  stopPolling();
  try {
    const snapshot = await window.otto.engine('thread.getSnapshot', { threadID });
    const bot = bots.find((candidate) => snapshot.thread.botProfileIDs.includes(candidate.id)) || null;
    const group = snapshot.thread.kind === 'group';
    chat = newChatState(threadID, group ? null : bot);
    chat.group = group;
    chat.teamID = group ? snapshot.thread.channelID : null;
    chat.title = snapshot.thread.title;
    chat.messages = snapshot.messages;
    chat.cursor = snapshot.lastEventSequence;
    chat.state = snapshot.thread.state;
    chat.activeRunID = snapshot.activeRunID ?? null;
    view = { type: 'chat', threadID, bot: chat.bot };
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
    if (content.runID && (event.kind === 'run.started' || event.kind === 'run.state_changed')) chat.activeRunID = content.runID;
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

/** Team rooms keep their messages in the room, so follow the room's snapshot. */
async function pollRoom() {
  const threadID = chat.threadID;
  const snapshot = await window.otto.engine('thread.getSnapshot', { threadID });
  if (chat?.threadID !== threadID) return;
  const before = JSON.stringify([chat.messages, chat.state]);
  chat.messages = snapshot.messages;
  chat.state = snapshot.thread.state;
  chat.activeRunID = snapshot.activeRunID ?? null;
  if (JSON.stringify([chat.messages, chat.state]) !== before) renderChat();
}

async function poll() {
  if (!chat?.threadID) return;
  const threadID = chat.threadID;
  try {
    if (chat.group) return await pollRoom();
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
  const element = el('div', `message ${message.role} ${message.kind}`);
  if (message.role === 'user') {
    element.textContent = message.text;
  } else if (message.kind === 'reasoning') {
    const details = el('details');
    details.append(el('summary', '', 'Thinking'), el('div', 'reasoning-body', message.text));
    element.append(details);
  } else if (message.kind === 'tool_call' || message.role === 'activity') {
    const details = el('details');
    details.append(el('summary', '', message.text.split('\n')[0].slice(0, 140) || 'Tool'));
    if (message.detail || message.text.includes('\n')) details.append(el('pre', '', message.detail || message.text));
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
  $('chat-face').replaceChildren(chat.group ? Icons.icon('person.2', 18) : Icons.face(name, 22));
  $('chat-edit-team').hidden = !chat.group;
  $('chat-name').textContent = name;
  $('chat-meta').textContent = STATE_LABELS[chat.state] ?? '';
  $('chat-stop').hidden = !(chat.state === 'working' && chat.activeRunID);
  $('composer-input').placeholder = `Message ${name}…`;

  const transcript = $('transcript');
  const nearBottom = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 80;
  transcript.replaceChildren();
  if (!chat.messages.length) {
    if (chat.group) transcript.append(el('div', 'transcript-empty', `Message the team. The orchestrator picks who acts; @mention a member to ask them directly.`));
    else transcript.append(el('div', 'transcript-empty', chat.bot?.jobTitle ? `${name} · ${chat.bot.jobTitle}` : `Say hello to ${name}.`));
  }
  let previousAuthor = null;
  for (const message of chat.messages) {
    // In a team, each reply says which bot wrote it.
    const author = message.author?.displayName;
    if (chat.group && message.role === 'assistant' && author && author !== previousAuthor) {
      const label = el('div', 'message-author');
      label.append(Icons.face(author, 18), el('span', '', author));
      transcript.append(label);
    }
    previousAuthor = message.role === 'assistant' ? author : null;
    transcript.append(messageElement(message));
  }
  if (chat.state === 'working') {
    const typing = el('div', 'typing');
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
      await window.otto.engine('message.send', { threadID: chat.threadID, clientMessageID: crypto.randomUUID().toUpperCase(), body });
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
    await window.otto.engine('approval.respond', { threadID: chat.threadID, requestID: request.requestID, nonce: request.nonce, decision });
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
    const option = el('option', '', provider.available ? provider.name : `${provider.name} (not installed)`);
    option.value = provider.id;
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
    if (surface === 'home') Home.render();
    openBot(bot);
  } catch (error) {
    toast(cleanError(error));
  }
}

// ---- Settings ------------------------------------------------------------------------------

function renderSettings() {
  const body = $('settings-body');
  body.replaceChildren();
  body.append(el('div', 'overline', 'Agents'));
  for (const agent of appState.agents.filter((candidate) => candidate.id !== 'shell')) {
    const row = el('div', 'setting-row');
    const text = el('div', 'setting-text');
    text.append(el('strong', '', agent.name), el('span', 'muted small', agent.available ? agent.path : 'Not installed'));
    const actions = el('div', 'setting-actions');
    if (agent.available && agent.canSignIn) {
      const signIn = el('button', 'ghost small-button', 'Sign in');
      signIn.title = `Opens ${agent.name}'s own sign-in in a terminal`;
      signIn.addEventListener('click', () => openTerminal(agent.id, true));
      actions.append(signIn);
    }
    if (!agent.available && agent.install) {
      const install = el('button', 'primary small-button', 'How to install');
      install.addEventListener('click', () => window.otto.openLink(agent.install));
      actions.append(install);
    }
    row.append(text, actions);
    body.append(row);
  }
  body.append(el('p', 'muted small', 'Sign-in runs in the agent itself, so your keys and passwords never pass through Otto. Restart Otto after installing an agent.'));

  const connectionsSlot = el('div');
  body.append(connectionsSlot);
  Connections.section().then((section) => connectionsSlot.replaceChildren(section));

  // On a Mac the engine's website accounts would share the Otto Mac app's stores; the Mac app
  // has its own Website Accounts, so the section is for Windows and Linux.
  if (appState.platform !== 'darwin') {
    const accountsSlot = el('div');
    body.append(accountsSlot);
    WebsiteAccounts.section().then((section) => accountsSlot.replaceChildren(section));
  }

  const voiceSlot = el('div');
  body.append(voiceSlot);
  Voice.settingsSection().then((section) => voiceSlot.replaceChildren(section));

  body.append(el('div', 'overline', 'Appearance'));
  const appearance = el('div', 'setting-row');
  const themeText = el('div', 'setting-text');
  themeText.append(el('strong', '', Theme.current.theme.displayName), el('span', 'muted small', 'Applies to this workspace.'));
  const themeButton = el('button', 'ghost small-button', 'Change theme');
  themeButton.addEventListener('click', toggleThemeMenu);
  appearance.append(themeText, themeButton);
  body.append(appearance);

  body.append(el('div', 'overline', 'Workspace'));
  const row = el('div', 'setting-row');
  const text = el('div', 'setting-text');
  text.append(el('strong', '', appState.workspaceName || 'None chosen'), el('span', 'muted small', appState.workspace || 'Pick the folder your bots and agents work in.'));
  const change = el('button', 'ghost small-button', appState.workspace ? 'Change folder' : 'Choose folder');
  change.addEventListener('click', chooseWorkspace);
  row.append(text, change);
  body.append(row);

  body.append(el('div', 'overline', 'About'));
  body.append(
    el('p', 'muted', [`Otto Desktop ${appState.version || ''}`.trim(), appState.daemon ? `engine ${appState.daemon.version}` : 'terminal engine offline', chatAvailable() ? 'chats on' : 'chats unavailable', appState.platform].join(' · ')),
  );
  const updates = el('div', 'setting-row');
  updates.id = 'update-row';
  body.append(updates);
  window.otto.updateState().then(renderUpdate);
}

// ---- Updates -------------------------------------------------------------------------------

const UPDATE_TEXT = {
  unsupported: ['Updates', 'This build updates through its installer, not in place.'],
  idle: ['Updates', 'Otto checks for updates every few hours.'],
  checking: ['Checking for updates…', ''],
  current: ['Otto is up to date', ''],
  available: ['Update available', ''],
  downloading: ['Downloading update…', ''],
  verifying: ['Checking the update’s signature…', ''],
  ready: ['Update ready', 'Restart Otto to finish.'],
  error: ['Update problem', ''],
};

/** Settings → About shows the update state with the next step, as the Mac does. */
function renderUpdate(state) {
  const row = $('update-row');
  if (!row || !state) return;
  row.replaceChildren();
  const [title, detail] = UPDATE_TEXT[state.phase] ?? UPDATE_TEXT.idle;
  const text = el('div', 'setting-text');
  const extra =
    state.phase === 'available' ? `Otto ${state.available}${state.notes ? ` · ${state.notes.split('\n')[0]}` : ''}` :
    state.phase === 'downloading' ? `${state.percent ?? 0}%` :
    state.phase === 'error' ? state.error :
    detail;
  text.append(el('strong', '', title), el('span', 'muted small', extra || `You have ${state.version}.`));
  const actions = el('div', 'setting-actions');
  const button = (label, primary, action) => {
    const control = el('button', `${primary ? 'primary' : 'ghost'} small-button`, label);
    control.addEventListener('click', action);
    actions.append(control);
  };
  if (state.phase === 'available') button('Download & Restart', true, () => window.otto.downloadUpdate());
  if (state.phase === 'ready') button('Restart now', true, () => window.otto.installUpdate());
  if (['idle', 'current', 'error'].includes(state.phase)) button('Check now', false, () => window.otto.checkForUpdate());
  row.append(text, actions);
}

let announcedUpdate = null;
window.otto.onUpdate((state) => {
  renderUpdate(state);
  // Mention a new version once; the download waits for the person to say so.
  if (state.phase === 'available' && announcedUpdate !== state.available) {
    announcedUpdate = state.available;
    toast(`Otto ${state.available} is available. Settings → About to update.`);
  }
  if (state.phase === 'ready') toast(`Otto ${state.available} is ready. Restart from Settings → About.`);
});

// ---- Theme menu ----------------------------------------------------------------------------

function toggleThemeMenu() {
  const menu = $('theme-menu');
  if (!menu.hidden) {
    menu.hidden = true;
    return;
  }
  menu.replaceChildren();
  for (const choice of Theme.current.themes) {
    const button = el('button');
    button.append(el('span', '', choice.name));
    if (choice.id === Theme.current.theme.id) button.append(el('span', 'check', '✓'));
    button.addEventListener('click', async () => {
      menu.hidden = true;
      try {
        await Theme.choose(choice.id);
        if (view.type === 'settings') renderSettings();
      } catch (error) {
        toast(cleanError(error));
      }
    });
    menu.append(button);
  }
  if (!Theme.current.themes.length) menu.append(el('button', '', 'Themes need the Otto engine'));
  menu.hidden = false;
}

// ---- Terminals -----------------------------------------------------------------------------

async function openTerminal(agentID, signIn = false) {
  if (surface !== 'chat') setSurface('chat');
  stopPolling();
  chat = null;
  showView('terminal');
  try {
    const sessionID = await Terminals.launch(agentID, signIn);
    showTerminal(sessionID);
  } catch (error) {
    toast(cleanError(error));
    goWelcome();
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
    await Theme.load();
    await refreshRoster();
    if (surface === 'home') Home.load();
    goWelcome();
  } catch (error) {
    toast(cleanError(error));
  }
}

function decorate() {
  document.body.classList.toggle('darwin', navigator.userAgent.includes('Mac'));
  $('toggle-sidebar').append(Icons.icon('sidebar.left', 15));
  $('theme-button').append(Icons.icon('paintpalette', 15));
  $('activity-button').prepend(Icons.icon('tray', 15));
  $('search-icon').append(Icons.icon('magnifyingglass', 14));
  $('new-chat').append(Icons.icon('plus', 15), el('span', '', 'New'));
  $('add-bot').append(Icons.icon('plus', 12));
  $('add-terminal').append(Icons.icon('plus', 12));
  $('add-team').append(Icons.icon('plus', 12));
  $('nav-settings').append(Icons.icon('gearshape', 13), el('span', '', 'Settings'));
  $('welcome-clip').append(Icons.icon('paperclip', 15));
  $('welcome-send').append(Icons.icon('arrow.up', 14));
  $('composer-send').append(Icons.icon('arrow.up', 15));
  $('new-document').append(Icons.icon('plus', 14), el('span', '', 'New'));
  $('editor-back').append(Icons.icon('chevron.left', 13), el('span', '', 'Documents'));
  $('new-dashboard').append(Icons.icon('plus', 13), el('span', '', 'New dashboard'));
  $('new-automation').append(Icons.icon('plus', 14), el('span', '', 'New'));
  $('note-back').append(Icons.icon('chevron.left', 13), el('span', '', 'Files & notes'));
  document.querySelector('.otto-face').append(Icons.face('Otto', 52));
}

decorate();
Home.configure({
  onError: (error) => toast(cleanError(error)),
  bots: () => bots,
  userName: () => appState?.userName || '',
  startChat,
  openBot,
  hire: openBotDialog,
  go,
});
Documents.onError = (error) => toast(cleanError(error));
Documents.onOpen = () => {
  view = { type: 'editor' };
  showView('editor');
  renderSidebar();
};
Memory.onError = (error) => toast(cleanError(error));
Places.onError = (error) => toast(cleanError(error));
Places.onOpenActivity = (item) => {
  const link = item.deepLink || {};
  const profileID = link.bot?.profileID || item.profileID;
  const bot = profileID && bots.find((candidate) => candidate.id === profileID);
  if (bot) return openBot(bot);
  if (link.routine) return go('automations');
  if (link.memory) return go('memory');
};
Places.onOpenNote = () => {
  view = { type: 'note' };
  showView('note');
  renderSidebar();
};
Places.wire();
Dashboards.configure({
  onError: (error) => toast(cleanError(error)),
  toast,
  bots: () => bots,
  hire: openBotDialog,
  ask: askBot,
});
$('new-dashboard').addEventListener('click', () => Dashboards.newDashboard());
BrowserPlace.configure({
  onError: (error) => toast(cleanError(error)),
  toast,
  bots: () => bots,
  // Native pages sit above the window's HTML, so step the page aside for the dialog.
  hire: () => {
    BrowserPlace.hide();
    openBotDialog();
  },
  ask: askBot,
});
BrowserPlace.wire();
$('note-back').addEventListener('click', () => go('files'));

$('surface-home').addEventListener('click', () => setSurface('home'));
$('surface-chat').addEventListener('click', () => setSurface('chat'));
$('activity-button').addEventListener('click', () => setSurface('home'));
$('theme-button').addEventListener('click', toggleThemeMenu);
$('workspace-button').addEventListener('click', chooseWorkspace);
$('choose-workspace').addEventListener('click', chooseWorkspace);
$('new-chat').addEventListener('click', () => go('welcome'));
$('add-bot').addEventListener('click', openBotDialog);
$('add-terminal').addEventListener('click', () => go('terminal'));
$('add-team').addEventListener('click', () => Teams.open());
$('chat-edit-team').addEventListener('click', () => chat?.teamID && Teams.open(chat.teamID));
Teams.configure({
  onError: (error) => toast(cleanError(error)),
  saved: async (team) => {
    await refreshRoster();
    renderSidebar();
    const saved = teams.find((candidate) => candidate.id === team.id);
    if (saved) await openTeam(saved);
  },
  deleted: async () => {
    await refreshRoster();
    go('welcome');
  },
});
Teams.wire();
Voice.configure({
  onError: (error) => toast(cleanError(error)),
  toast,
  openSettings: () => go('settings'),
});
Voice.wire();
Connections.configure({ onError: (error) => toast(cleanError(error)) });
WebsiteAccounts.configure({ onError: (error) => toast(cleanError(error)), bots: () => bots });
$('welcome-mic').append(Icons.icon('mic', 15));
$('composer-mic').append(Icons.icon('mic', 15));
$('welcome-mic').addEventListener('click', () => Voice.dictate($('welcome-input'), $('welcome-mic')));
$('composer-mic').addEventListener('click', () => Voice.dictate($('composer-input'), $('composer-mic')));
$('nav-settings').addEventListener('click', () => go('settings'));
$('sidebar-search').addEventListener('input', (event) => {
  railQuery = event.target.value;
  renderSidebar();
});
$('new-document').addEventListener('click', () => Documents.create('document'));
$('new-sheet').addEventListener('click', () => Documents.create('spreadsheet'));
$('editor-back').addEventListener('click', () => go('documents'));
$('composer').addEventListener('submit', sendMessage);
$('composer-input').addEventListener('input', autosize);
$('composer-input').addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    $('composer').requestSubmit();
  }
});
$('welcome-input').addEventListener('input', (event) => $('welcome-send').classList.toggle('ready', Boolean(event.target.value.trim())));
$('welcome-composer').addEventListener('submit', (event) => {
  event.preventDefault();
  const text = $('welcome-input').value.trim();
  if (!welcomeTarget) return openBotDialog();
  if (!text) return;
  $('welcome-input').value = '';
  startChat(welcomeTarget, text);
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
document.addEventListener('click', (event) => {
  if (!event.target.closest('#theme-menu, #theme-button') && !$('theme-menu').hidden) $('theme-menu').hidden = true;
});
window.addEventListener('resize', () => {
  if (view.type === 'terminal') Terminals.fitActive(view.sessionID);
});
setInterval(async () => {
  await refreshRoster();
  if (surface === 'chat') renderSidebar();
  if (surface === 'chat' && view.type === 'welcome') renderWelcome();
  if (surface === 'home') await Home.load();
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
  goWelcome();
});

window.otto
  .state()
  .then(async (state) => {
    appState = state;
    if (chatAvailable()) await Theme.load();
    await refreshRoster();
    goWelcome();
    setSurface(chatAvailable() ? 'home' : 'chat');
  })
  .catch((error) => {
    appState = { agents: [], providers: [], workspace: null, chat: { available: false } };
    goWelcome();
    setSurface('chat');
    toast(cleanError(error));
  });
