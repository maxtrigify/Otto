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
