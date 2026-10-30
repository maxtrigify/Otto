// Live: a real bot conversation through otto-engine. Opt-in because it uses the machine's agent
// account: OTTO_ENGINE_PATH=... OTTO_ENGINE_LIVE="Claude Code" node --test test/engine-live.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { EngineClient } = require('../src/engine');
const { loginEnvironment } = require('../src/agents');

const binary = process.env.OTTO_ENGINE_PATH;
const provider = process.env.OTTO_ENGINE_LIVE;

test('a bot answers a message end to end', { skip: !binary || !provider, timeout: 300_000 }, async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'otto-engine-live-'));
  const workspace = path.join(root, 'Workspace');
  fs.mkdirSync(workspace);
  const client = new EngineClient({
    binary,
    stateDirectory: path.join(root, 'state'),
    workspace,
    env: loginEnvironment(),
  });
  const logs = [];
  client.on('log', (text) => logs.push(text.trim()));
  t.after(() => {
    client.dispose();
    fs.rmSync(root, { recursive: true, force: true });
  });

  await client.start();
  const bot = await client.call('bot.create', {
    name: 'Desk',
    responsibility: 'Answer questions briefly',
    provider,
  });
  assert.equal(bot.provider, provider);

  const marker = 'otto-engine-ok';
  const started = await client.startThread(bot.id, `Reply with exactly this and nothing else: ${marker}`);
  const threadID = started.thread.id;

  const seen = [];
  let cursor = 0;
  const deadline = Date.now() + 240_000;
  let answered = false;
  while (Date.now() < deadline && !answered) {
    const page = await client.events(threadID, cursor);
    for (const event of page.events) {
      cursor = Math.max(cursor, event.sequence);
      const message = event.content.message;
      seen.push(`${event.kind}${message ? ` [${message.role}/${message.kind}] ${message.text.slice(0, 120)}` : ''}${event.content.state ? ` → ${event.content.state}` : ''}`);
      if (message?.role === 'assistant' && message.kind === 'text' && message.text.includes(marker)) answered = true;
    }
    if (!answered) await new Promise((resolve) => setTimeout(resolve, 500));
  }
  const snapshot = await client.snapshot(threadID);
  console.log(seen.join('\n'));
  assert.ok(answered, `no answer. events:\n${seen.join('\n')}\nlogs:\n${logs.join('\n')}`);
  assert.ok(snapshot.messages.some((message) => message.role === 'user'), 'user message missing');
});
