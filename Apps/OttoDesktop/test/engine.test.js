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
