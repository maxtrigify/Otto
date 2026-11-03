// End-to-end: drives a real otto-engine binary (OTTO_ENGINE_PATH) through the desktop client.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { EngineClient } = require('../src/engine');

const binary = process.env.OTTO_ENGINE_PATH;

async function engine(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'otto-engine-'));
  const workspace = path.join(root, 'Workspace');
  fs.mkdirSync(workspace);
  const client = new EngineClient({ binary, stateDirectory: path.join(root, 'state'), workspace });
  const logs = [];
  client.on('log', (text) => logs.push(text.trim()));
  t.after(async () => {
    await client.stop();
    fs.rmSync(root, { recursive: true, force: true });
  });
  return { client, workspace, logs };
}

test('the engine starts for a workspace and reports its capabilities', { skip: !binary }, async (t) => {
  const { client, logs } = await engine(t);
  const capabilities = await client.start();
  assert.ok(capabilities.supportedProtocolVersions.includes(1), JSON.stringify(capabilities));
  assert.ok(capabilities.environment, JSON.stringify(capabilities));
  assert.ok(logs.some((line) => line.includes('otto-engine ready')), logs.join('\n'));
});

test('bots and threads list through the host RPC', { skip: !binary }, async (t) => {
  const { client } = await engine(t);
  await client.start();
  const roster = await client.bots();
  assert.ok(Array.isArray(roster.bots));
  assert.ok(Array.isArray(roster.teams));
  const threads = await client.threads();
  assert.ok(Array.isArray(threads));
  console.log(`bots: ${roster.bots.map((bot) => `${bot.name} (${bot.provider})`).join(', ') || 'none'}`);
});

test('the engine rejects requests with the wrong token', { skip: !binary }, async (t) => {
  const { client } = await engine(t);
  await client.start();
  client.token = 'f'.repeat(64);
  await assert.rejects(client.threads(), (error) => error.code === 'unauthorized');
});

test('Home: the brief, to-dos and reviews come through the desktop API', { skip: !binary }, async (t) => {
  const { client } = await engine(t);
  await client.start();
  const home = await client.desktop('home.snapshot');
  assert.equal(typeof home.profile, 'string');
  for (const key of ['todos', 'updates', 'events', 'cards', 'reviews']) assert.ok(Array.isArray(home[key]), key);

  const added = await client.desktop('brief.addTodo', { title: 'Ship Otto Desktop' });
  const todo = added.todos.find((item) => item.title === 'Ship Otto Desktop');
  assert.ok(todo, JSON.stringify(added.todos));
  const done = await client.desktop('brief.complete', { id: todo.id, completed: true });
  const completed = done.todos.find((item) => item.id === todo.id);
  assert.ok(!completed || completed.completedAt, 'completed to-do should be marked or leave the list');
});

test('Documents: create, save and read back a Word document and a sheet', { skip: !binary }, async (t) => {
  const { client } = await engine(t);
  await client.start();
  const doc = await client.desktop('documents.create', { kind: 'document', title: 'Launch notes' });
  assert.equal(doc.kind, 'document');
  await client.desktop('documents.saveText', { path: doc.path, text: 'Otto on Windows\nand Linux' });
  const read = await client.desktop('documents.read', { path: doc.path });
  assert.equal(read.text.trim(), 'Otto on Windows\nand Linux');

  const sheet = await client.desktop('documents.create', { kind: 'spreadsheet', title: 'Budget' });
  const sheetContent = await client.desktop('documents.read', { path: sheet.path });
  assert.ok(sheetContent.sheet, JSON.stringify(sheetContent));

  const list = await client.desktop('documents.list');
  assert.deepEqual(new Set(list.map((file) => file.title)), new Set(['Launch notes', 'Budget']));
});

test('the desktop API rejects unknown methods', { skip: !binary }, async (t) => {
  const { client } = await engine(t);
  await client.start();
  await assert.rejects(client.desktop('home.delete-everything'), (error) => error.code === 'unknown_method');
});

test('Memory: About me entries can be added and forgotten', { skip: !binary }, async (t) => {
  const { client } = await engine(t);
  await client.start();
  const empty = await client.desktop('memory.snapshot');
  for (const key of ['personal', 'operating', 'brain']) assert.ok(Array.isArray(empty[key]), key);
  const added = await client.desktop('memory.addPersonal', { text: 'Prefers short answers' });
  const entry = added.personal.find((item) => item.text === 'Prefers short answers');
  assert.ok(entry, JSON.stringify(added.personal));
  const removed = await client.desktop('memory.removePersonal', { id: entry.id });
  assert.ok(!removed.personal.some((item) => item.id === entry.id));
});

test('Automations: create, pause, resume and delete', { skip: !binary }, async (t) => {
  const { client } = await engine(t);
  await client.start();
  const empty = await client.desktop('automations.list');
  assert.deepEqual(empty.automations, []);
  assert.ok(Array.isArray(empty.runs));

  const created = await client.desktop('automations.create', {
    name: 'Morning digest',
    instruction: 'Summarise what changed overnight',
    everyMinutes: 120,
  });
  const automation = created.automations.find((item) => item.name === 'Morning digest');
  assert.ok(automation, JSON.stringify(created));
  assert.equal(automation.enabled, false);
  assert.equal(automation.trigger, 'Every 2h');

  const weekday = await client.desktop('automations.create', {
    name: 'Inbox triage',
    instruction: 'List what needs a reply',
    cron: '0 8 * * 1-5',
  });
  const triage = weekday.automations.find((item) => item.name === 'Inbox triage');
  assert.equal(triage.trigger, 'Weekdays at 08:00');
  await client.desktop('automations.delete', { id: triage.id });

  const enabled = await client.desktop('automations.setEnabled', { id: automation.id, enabled: true });
  assert.equal(enabled.automations.find((item) => item.id === automation.id).enabled, true);
  const paused = await client.desktop('automations.setEnabled', { id: automation.id, enabled: false });
  assert.equal(paused.automations.find((item) => item.id === automation.id).enabled, false);

  await assert.rejects(client.desktop('automations.create', { name: '', instruction: 'x' }));
  const deleted = await client.desktop('automations.delete', { id: automation.id });
  assert.deepEqual(deleted.automations, []);
});

test('Activity: the snapshot lists what needs you and what is running', { skip: !binary }, async (t) => {
  const { client } = await engine(t);
  await client.start();
  const activity = await client.desktop('activity.snapshot');
  assert.ok(Array.isArray(activity.needsYou));
  assert.ok(Array.isArray(activity.active));
});

test('Files & notes: Markdown notes list, read and save; Otto state stays hidden', { skip: !binary }, async (t) => {
  const { client, workspace } = await engine(t);
  fs.mkdirSync(path.join(workspace, 'Notes'));
  fs.writeFileSync(path.join(workspace, 'Notes', 'Plan.md'), '# Plan\n\nShip it');
  fs.mkdirSync(path.join(workspace, 'node_modules', 'pkg'), { recursive: true });
  fs.writeFileSync(path.join(workspace, 'node_modules', 'pkg', 'README.md'), 'hidden');
  await client.start();

  const notes = await client.desktop('files.list');
  const paths = notes.map((note) => note.path.replaceAll('\\', '/'));
  assert.ok(paths.includes('Notes/Plan.md'), JSON.stringify(paths));
  assert.ok(!paths.some((item) => item.includes('node_modules') || item.startsWith('.otto')), JSON.stringify(paths));
  assert.equal(notes.find((note) => note.path.replaceAll('\\', '/') === 'Notes/Plan.md').title, 'Plan');

  const read = await client.desktop('files.read', { path: 'Notes/Plan.md' });
  assert.equal(read.text, '# Plan\n\nShip it');
  await client.desktop('files.save', { path: 'Notes/Plan.md', text: '# Plan\n\nShipped' });
  assert.equal(fs.readFileSync(path.join(workspace, 'Notes', 'Plan.md'), 'utf8'), '# Plan\n\nShipped');
  await assert.rejects(client.desktop('files.read', { path: '../outside.md' }));
});

test('Dashboards: pages of cards can be made, styled, filled and removed', { skip: !binary }, async (t) => {
  const { client } = await engine(t);
  await client.start();
  const empty = await client.desktop('dashboards.snapshot');
  assert.deepEqual(empty, { dashboards: [], cards: [] });

  const created = await client.desktop('dashboards.create', { name: 'Revenue' });
  const revenue = created.dashboards.find((item) => item.name === 'Revenue');
  assert.ok(revenue, JSON.stringify(created));

  const renamed = await client.desktop('dashboards.rename', { id: revenue.id, name: 'Money' });
  assert.equal(renamed.dashboards[0].name, 'Money');
  const styled = await client.desktop('dashboards.setLook', { id: revenue.id, accent: 'purple', cardStyle: 'solid' });
  assert.equal(styled.dashboards[0].accent, 'purple');
  assert.equal(styled.dashboards[0].cardStyle, 'solid');

  await client.desktop('cards.add', {
    dashboardID: revenue.id,
    title: 'MRR',
    style: 'metrics',
    rows: [{ label: 'MRR', value: '$12,400', history: [11000, 11800, 12400] }],
  });
  const filled = await client.desktop('cards.add', {
    dashboardID: revenue.id,
    title: 'Signups',
    style: 'line',
    rows: [{ label: 'Mon', value: '4' }, { label: 'Tue', value: '9' }],
  });
  assert.deepEqual(filled.cards.map((card) => card.title), ['MRR', 'Signups']);
  const signups = filled.cards.find((card) => card.title === 'Signups');
  assert.equal(signups.dashboardID, revenue.id);

  const moved = await client.desktop('cards.move', { id: signups.id, offset: -1 });
  assert.deepEqual(moved.cards.map((card) => card.title), ['Signups', 'MRR']);
  const wide = await client.desktop('cards.setLook', { id: signups.id, width: 'wide', color: 'green' });
  const wideCard = wide.cards.find((card) => card.id === signups.id);
  assert.equal(wideCard.width, 'wide');
  assert.equal(wideCard.color, 'green');
  await assert.rejects(client.desktop('cards.add', { dashboardID: revenue.id, title: 'x', style: 'pie' }));

  const removed = await client.desktop('cards.remove', { id: signups.id });
  assert.deepEqual(removed.cards.map((card) => card.title), ['MRR']);
  const gone = await client.desktop('dashboards.delete', { id: revenue.id });
  assert.deepEqual(gone, { dashboards: [], cards: [] });
});

test('Browser: the desktop renders engine browsers and answers page reads for bots', { skip: !binary }, async (t) => {
  const { client } = await engine(t);
  const events = [];
  const calls = [];
  client.on('event', (event) => events.push(event));
  // Play the renderer: answer the engine's host calls the way Otto Desktop's browser host does.
  client.on('host', (call) => {
    calls.push(call.method);
    if (call.method === 'browser.prepare') return client.reply(call.id, true);
    if (call.method === 'browser.eval') {
      assert.match(call.params.script, /__ottoAgentPage/);
      return client.reply(
        call.id,
        JSON.stringify({
          url: 'https://example.com/',
          title: 'Example Domain',
          revision: 'r1',
          elements: [{ id: 'e1', role: 'link', name: 'More information', placeholder: null, bounds: { x: 1, y: 2, width: 3, height: 4 }, actions: ['click'], isDisabled: false, isSensitive: false }],
        }),
      );
    }
    client.reply(call.id, null, `unexpected ${call.method}`);
  });
  await client.start();
  assert.deepEqual(await client.desktop('browser.list'), []);

  const opened = await client.desktop('browser.open', { url: 'https://example.com/' });
  assert.equal(opened.length, 1);
  const browser = opened[0];
  assert.equal(browser.state.tabs.length, 1);
  assert.equal(browser.state.url, 'https://example.com/');

  // The engine tells the desktop about the new browser so it can load the page.
  for (let attempt = 0; attempt < 20 && !events.some((event) => event.kind === 'browser.state'); attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const state = events.find((event) => event.kind === 'browser.state');
  assert.ok(state, JSON.stringify(events));
  assert.equal(state.payload.nodeID, browser.nodeID);

  await client.desktop('browser.reportLoaded', {
    nodeID: browser.nodeID,
    tabID: browser.state.activeTabID,
    url: 'https://example.com/',
    title: 'Example Domain',
    canGoBack: false,
    canGoForward: false,
    isLoading: false,
    revision: state.payload.state.revision,
  });
  const loaded = await client.desktop('browser.list');
  assert.equal(loaded[0].state.title, 'Example Domain');

  const page = await client.desktop('browser.inspect', { id: browser.nodeID });
  assert.equal(page.pageRevision, 'r1');
  assert.equal(page.elements[0].name, 'More information');
  assert.ok(calls.includes('browser.prepare') && calls.includes('browser.eval'), calls.join(','));

  const tabbed = await client.desktop('browser.open', { url: 'https://example.org/', nodeID: browser.nodeID });
  assert.equal(tabbed[0].state.tabs.length, 2);
  const closed = await client.desktop('browser.closeTab', { nodeID: browser.nodeID, tabID: tabbed[0].state.activeTabID });
  assert.equal(closed[0].state.tabs.length, 1);
  assert.deepEqual(await client.desktop('browser.close', { id: browser.nodeID }), []);
});

test('Teams: a group of bots is created, chats as a thread, is edited and removed', { skip: !binary }, async (t) => {
  const { client } = await engine(t);
  await client.start();
  const scout = await client.call('bot.create', { name: 'Scout', responsibility: 'Research', provider: 'Claude Code' });
  const quill = await client.call('bot.create', { name: 'Quill', responsibility: 'Write', provider: 'Codex' });
  const roster = await client.desktop('teams.roster');
  assert.deepEqual(roster.map((bot) => bot.handle).sort(), ['quill', 'scout']);

  await assert.rejects(client.desktop('teams.create', { memberProfileIDs: [scout.id] }));
  const team = await client.desktop('teams.create', {
    name: 'Launch crew',
    instructions: '@scout researches, @quill writes.',
    memberProfileIDs: [scout.id, quill.id],
    orchestratorProfileID: quill.id,
    permissionMode: 'workspaceWrite',
  });
  assert.equal(team.name, 'Launch crew');
  assert.equal(team.orchestratorProfileID, quill.id);
  assert.equal(team.permissionMode, 'workspaceWrite');

  // The team's room is an ordinary thread on the host RPC, so the chat UI works unchanged.
  const { teams } = await client.bots();
  assert.equal(teams.length, 1);
  assert.equal(teams[0].id, team.id);
  const threads = await client.threads();
  const room = threads.find((thread) => thread.id === team.threadID);
  assert.ok(room, JSON.stringify(threads));
  assert.equal(room.kind, 'group');
  const snapshot = await client.snapshot(team.threadID);
  assert.deepEqual(snapshot.messages, []);

  const edited = await client.desktop('teams.update', {
    id: team.id,
    name: 'Launch',
    instructions: team.instructions,
    memberProfileIDs: [scout.id, quill.id],
    orchestratorProfileID: scout.id,
    permissionMode: 'unrestricted',
  });
  assert.equal(edited.name, 'Launch');
  assert.equal(edited.orchestratorProfileID, scout.id);
  assert.equal((await client.desktop('teams.get', { id: team.id })).permissionMode, 'unrestricted');

  assert.equal(await client.desktop('teams.delete', { id: team.id }), true);
  assert.deepEqual((await client.bots()).teams, []);
  await assert.rejects(client.desktop('teams.get', { id: team.id }));
});

test('Voice: keys live in the desktop keychain and Talk runs the Mac voice session over desktop audio', { skip: !binary, timeout: 60_000 }, async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'otto-engine-voice-'));
  const workspace = path.join(root, 'Workspace');
  const state = path.join(root, 'state');
  fs.mkdirSync(workspace);
  fs.mkdirSync(state, { recursive: true });
  // An older engine kept secrets in its state folder; they move into the keychain.
  fs.writeFileSync(path.join(state, 'secrets.json'), JSON.stringify({ 'legacy.key': 'old-secret' }));
  const client = new EngineClient({ binary, stateDirectory: state, workspace, desktopSecrets: true });
  t.after(async () => {
    await client.stop();
    fs.rmSync(root, { recursive: true, force: true });
  });

  // Play Otto Desktop: the keychain, the microphone and speakers, and the provider WebSocket.
  const keychain = new Map();
  const sockets = [];
  const sent = [];
  const played = [];
  const calls = [];
  client.on('host', ({ id, method, params }) => {
    calls.push(method);
    if (method === 'secrets.get') return client.reply(id, keychain.get(params.key) ?? null);
    if (method === 'secrets.set') return client.reply(id, keychain.set(params.key, params.value) && true);
    if (method === 'secrets.delete') return client.reply(id, keychain.delete(params.key) || true);
    if (method === 'socket.open') {
      sockets.push(params);
      return client.reply(id, true);
    }
    if (method.startsWith('audio.')) return client.reply(id, true);
    if (method.startsWith('browser.')) return client.reply(id, true);
    client.reply(id, null, `unexpected ${method}`);
  });
  client.on('event', ({ kind, payload }) => {
    if (kind === 'socket.send') sent.push(JSON.parse(payload.text));
    if (kind === 'audio.play') played.push(payload.pcm);
  });
  const until = async (check, what) => {
    for (let attempt = 0; attempt < 100; attempt += 1) {
      const value = check();
      if (value) return value;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assert.fail(`timed out waiting for ${what}. host calls: ${calls.join(', ')}`);
  };

  await client.start();
  assert.equal(keychain.get('legacy.key'), 'old-secret');
  assert.ok(!fs.existsSync(path.join(state, 'secrets.json')), 'the plain-text secrets file is removed');

  const off = await client.desktop('voice.status');
  assert.equal(off.state, 'disconnected');
  assert.deepEqual(off.keys, { openai: false, xai: false });
  assert.ok(off.voices.openai.length && off.voices.xai.length);

  const keyed = await client.desktop('voice.setKey', { provider: 'openai', key: 'sk-test-123' });
  assert.equal(keyed.keys.openai, true);
  assert.equal(keychain.get('openai.api-key'), 'sk-test-123');

  const talking = client.desktop('voice.talk');
  const socket = await until(() => sockets[0], 'the provider socket');
  assert.match(socket.url, /^wss:\/\/api\.openai\.com\/v1\/realtime/);
  assert.equal(socket.headers.Authorization ?? socket.headers.authorization, 'Bearer sk-test-123');
  const update = await until(() => sent.find((message) => message.type === 'session.update'), 'session.update');
  assert.match(update.session.instructions, /You are Otto/);
  assert.ok(update.session.tools.length > 10, `tools: ${update.session.tools.length}`);
  client.event(`socket.message.${socket.id}`, { id: socket.id, text: JSON.stringify({ type: 'session.updated' }) });
  await talking;
  await until(() => calls.includes('audio.start'), 'the microphone');

  // Microphone audio reaches the provider, and the provider's voice plays in the desktop.
  const pcm = Buffer.alloc(1920, 7).toString('base64');
  client.event('audio.input', { pcm });
  await until(() => sent.some((message) => message.type === 'input_audio_buffer.append'), 'microphone audio at the provider');
  const spoken = Buffer.alloc(960, 3).toString('base64');
  client.event(`socket.message.${socket.id}`, { id: socket.id, text: JSON.stringify({ type: 'response.output_audio.delta', delta: spoken }) });
  await until(() => played.length, 'speaker audio');

  const asleep = await client.desktop('voice.sleep');
  assert.notEqual(asleep.state, 'listening');
});
