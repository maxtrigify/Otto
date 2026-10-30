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

test('a shell session runs commands, resizes and stops through ottod', { skip: !binary }, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'otto-desktop-'));
  const workspace = path.join(root, 'workspace');
  fs.mkdirSync(workspace);
  const client = new OttodClient({ binary, stateDirectory: path.join(root, 'state'), workspaces: [workspace] });
  const output = new Map();
  const ended = new Set();
  client.on('event', (event) => {
    if (event.kind === 'session.output') {
      const text = Buffer.from(event.payload.data, 'base64').toString('utf8');
      output.set(event.sessionID, (output.get(event.sessionID) || '') + text);
    }
    if (event.kind === 'session.exited') ended.add(event.sessionID);
  });
  try {
    const hello = await client.start();
    assert.equal(hello.protocolVersion, 1);

    const shell = discoverAgents(loginEnvironment()).find((agent) => agent.id === 'shell');
    const { sessionID } = await client.launch({
      executable: shell.executable,
      workspace,
      columns: 100,
      rows: 30,
    });
    await client.resize(sessionID, 120, 40);
    const marker = 'otto-desktop-ok';
    await client.input(sessionID, isWindows ? `Write-Output ${marker}\r` : `echo ${marker}-$((40+2))\r`);
    const expected = isWindows ? marker : `${marker}-42`;
    await waitFor(() => (output.get(sessionID) || '').includes(expected));

    await client.input(sessionID, 'exit\r');
    await waitFor(() => ended.has(sessionID));
  } finally {
    client.dispose();
    fs.rmSync(root, { recursive: true, force: true });
  }
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
