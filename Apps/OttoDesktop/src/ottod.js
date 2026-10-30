// Runs `ottod stdio` as a child process and speaks its JSON-lines remote protocol
// (Sources/OttoRemote/RemoteModels.swift). The token never leaves this process.
'use strict';

const { spawn } = require('node:child_process');
const { EventEmitter } = require('node:events');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');

const REQUEST_TIMEOUT_MS = 15_000;
const EVENT_PAGE = 500;
const IDLE_POLL_MS = 40;

class OttodClient extends EventEmitter {
  constructor({ binary, stateDirectory, workspaces, env = process.env }) {
    super();
    this.binary = binary;
    this.stateDirectory = stateDirectory;
    this.workspaces = workspaces;
    this.env = env;
    this.pending = new Map();
    this.cursor = 0;
    this.child = null;
    this.polling = false;
    this.running = false;
  }

  /** Writes a fresh owner-only token, starts the daemon and returns its hello. */
  async start() {
    fs.mkdirSync(this.stateDirectory, { recursive: true, mode: 0o700 });
    this.token = crypto.randomBytes(32).toString('hex');
    const tokenFile = path.join(this.stateDirectory, 'desktop.token');
    fs.writeFileSync(tokenFile, this.token, { mode: 0o600 });
    fs.chmodSync(tokenFile, 0o600);

    const args = ['stdio', '--token-file', tokenFile, '--state-dir', this.stateDirectory];
    for (const workspace of this.workspaces) args.push('--workspace', workspace);
    this.child = spawn(this.binary, args, { env: this.env, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    this.child.stdin.on('error', () => {});
    readline.createInterface({ input: this.child.stdout }).on('line', (line) => this.receive(line));
    this.child.stderr.on('data', (chunk) => this.emit('log', chunk.toString()));
    this.child.on('error', (error) => this.fail(error));
    this.running = true;
    this.child.on('exit', (code, signal) => {
      this.running = false;
      this.fail(new Error(`ottod exited (${signal ?? code})`));
      this.emit('exit', { code, signal });
    });

    // Only events from this run matter: earlier sessions' processes are gone.
    const probe = await this.request('hello', { afterSequence: 0, limit: 1 });
    this.cursor = probe.eventPage.latestSequence;
    this.pollEvents();
    return probe;
  }

  request(method, parameters) {
    if (!this.running) {
      return Promise.reject(new Error('ottod is not running'));
    }
    const id = crypto.randomUUID();
    const line = JSON.stringify({ id, token: this.token, method, parameters }) + '\n';
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`ottod did not answer ${method}`));
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(line);
    });
  }

  receive(line) {
    let response;
    try {
      response = JSON.parse(line);
    } catch {
      this.emit('log', `unparseable ottod output: ${line.slice(0, 200)}`);
      return;
    }
    const waiter = this.pending.get(response.id);
    if (!waiter) return;
    this.pending.delete(response.id);
    clearTimeout(waiter.timer);
    if (response.error) {
      const error = new Error(response.error.message);
      error.code = response.error.code;
      waiter.reject(error);
    } else {
      waiter.resolve(response.result);
    }
  }

  async pollEvents() {
    if (this.polling) return;
    this.polling = true;
    while (this.running) {
      let page;
      try {
        page = await this.request('events', { afterSequence: this.cursor, limit: EVENT_PAGE });
      } catch (error) {
        if (!this.running) break;
        this.emit('log', `event poll failed: ${error.message}`);
        await delay(500);
        continue;
      }
      for (const event of page.events) {
        this.cursor = Math.max(this.cursor, event.sequence);
        this.emit('event', event);
      }
      if (page.events.length < EVENT_PAGE) await delay(IDLE_POLL_MS);
    }
    this.polling = false;
  }

  launch({ executable, args = [], workspace, columns, rows }) {
    return this.request('launch', {
      executable,
      arguments: args,
      workspacePath: workspace,
      columns,
      rows,
    });
  }

  input(sessionID, text) {
    return this.request('input', { sessionID, data: Buffer.from(text, 'utf8').toString('base64') });
  }

  resize(sessionID, columns, rows) {
    return this.request('resize', { sessionID, columns, rows });
  }

  stop(sessionID) {
    return this.request('stop', { sessionID });
  }

  fail(error) {
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer);
      reject(error);
    }
    this.pending.clear();
  }

  dispose() {
    if (this.running) {
      this.running = false;
      this.fail(new Error('ottod was stopped'));
      this.child.stdin.end();
      this.child.kill();
    }
  }
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

module.exports = { OttodClient };
