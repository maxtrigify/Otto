// End-to-end: drives a real ottod binary (OTTOD_PATH) through the desktop bridge.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { OttodClient } = require('../src/ottod');
const { discoverAgents, loginEnvironment } = require('../src/agents');

const binary = process.env.OTTOD_PATH;
const isWindows = process.platform === 'win32';

function waitFor(predicate, timeoutMs = 10_000) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const timer = setInterval(() => {
      if (predicate()) {
        clearInterval(timer);
        resolve();
      } else if (Date.now() - started > timeoutMs) {
        clearInterval(timer);
        reject(new Error('timed out'));
      }
    }, 20);
  });
}

async function harness(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'otto-desktop-'));
  const workspace = path.join(root, 'workspace');
  fs.mkdirSync(workspace);
  const client = new OttodClient({ binary, stateDirectory: path.join(root, 'state'), workspaces: [workspace] });
  const output = new Map();
  const events = [];
  const ended = new Set();
  client.on('log', (text) => events.push(`[ottod stderr] ${text.trim()}`));
  client.on('event', (event) => {
    if (event.kind === 'session.output') {
      const text = Buffer.from(event.payload.data, 'base64').toString('utf8');
      output.set(event.sessionID, (output.get(event.sessionID) || '') + text);
      events.push(`${event.kind} ${JSON.stringify(text)}`);
    } else {
      events.push(`${event.kind} ${JSON.stringify(event.payload ?? null)}`);
    }
    if (event.kind === 'session.exited') ended.add(event.sessionID);
  });
  t.after(() => {
    client.dispose();
    fs.rmSync(root, { recursive: true, force: true });
  });
  const expect = async (label, predicate, timeoutMs = 20_000) => {
    try {
      await waitFor(predicate, timeoutMs);
    } catch {
      throw new Error(`${label} timed out. Events:\n${events.join('\n') || '(none)'}`);
    }
  };
  return { client, workspace, output, ended, expect };
}

test('a one-shot command streams its output and exit through ottod', { skip: !binary }, async (t) => {
  const { client, workspace, output, ended, expect } = await harness(t);
  await client.start();
  const command = isWindows
    ? { executable: path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'cmd.exe'), args: ['/d', '/c', 'echo otto-one-shot'] }
    : { executable: '/bin/echo', args: ['otto-one-shot'] };
  const { sessionID } = await client.launch({ ...command, workspace, columns: 80, rows: 24 });
  await expect('one-shot output', () => (output.get(sessionID) || '').includes('otto-one-shot'));
  await expect('one-shot exit', () => ended.has(sessionID));
});

test('a shell session runs commands, resizes and stops through ottod', { skip: !binary }, async (t) => {
  const { client, workspace, output, ended, expect } = await harness(t);
  const hello = await client.start();
  assert.equal(hello.protocolVersion, 1);

  const shell = discoverAgents(loginEnvironment()).find((agent) => agent.id === 'shell');
  const { sessionID } = await client.launch({ executable: shell.executable, workspace, columns: 100, rows: 30 });
  const seen = () => output.get(sessionID) || '';
  // PowerShell takes a few seconds to load profiles; type once its prompt is up.
  if (isWindows) await expect('PowerShell prompt', () => /PS [A-Z]:\\/.test(seen()), 45_000);
  await client.resize(sessionID, 120, 40);
  const marker = 'otto-desktop-ok';
  await client.input(sessionID, isWindows ? `Write-Output "${marker}-$(40+2)"\r` : `echo ${marker}-$((40+2))\r`);
  await expect('command output', () => seen().includes(`${marker}-42`));

  await client.input(sessionID, 'exit\r');
  await expect('shell exit', () => ended.has(sessionID));
});

test('ottod rejects launches outside the workspace', { skip: !binary }, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'otto-desktop-'));
  const workspace = path.join(root, 'workspace');
  fs.mkdirSync(workspace);
  const client = new OttodClient({ binary, stateDirectory: path.join(root, 'state'), workspaces: [workspace] });
  try {
    await client.start();
    const shell = discoverAgents(loginEnvironment()).find((agent) => agent.id === 'shell');
    await assert.rejects(
      client.launch({ executable: shell.executable, workspace: os.tmpdir(), columns: 80, rows: 24 }),
      (error) => error.code === 'workspace_denied' || /workspace/i.test(error.message),
    );
  } finally {
    client.dispose();
    fs.rmSync(root, { recursive: true, force: true });
  }
});
