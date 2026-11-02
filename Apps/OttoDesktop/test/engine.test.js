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
  t.after(() => {
    client.dispose();
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
