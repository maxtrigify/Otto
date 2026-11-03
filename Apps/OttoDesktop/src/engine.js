// Runs `otto-engine stdio` (the full Otto engine for one workspace) and speaks its host RPC
// (Sources/OttoRPCContracts). The token never leaves this process.
'use strict';

const { spawn } = require('node:child_process');
const { EventEmitter } = require('node:events');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');

const REQUEST_TIMEOUT_MS = 60_000;
const PROTOCOL_VERSION = 1;

class EngineClient extends EventEmitter {
  /** `desktopSecrets`: secrets live in Otto Desktop's OS keychain (the engine asks for them). */
  constructor({ binary, stateDirectory, workspace, env = process.env, desktopSecrets = false }) {
    super();
    this.desktopSecrets = desktopSecrets;
    this.binary = binary;
    this.stateDirectory = stateDirectory;
    this.workspace = workspace;
    this.env = env;
    this.pending = new Map();
    this.running = false;
  }

  /** Writes a fresh owner-only token, starts the engine and resolves once it answers. */
  async start() {
    fs.mkdirSync(this.stateDirectory, { recursive: true, mode: 0o700 });
    this.token = crypto.randomBytes(32).toString('hex');
    const tokenFile = path.join(this.stateDirectory, 'desktop.token');
    fs.writeFileSync(tokenFile, this.token, { mode: 0o600 });
    fs.chmodSync(tokenFile, 0o600);

    const args = ['stdio', '--token-file', tokenFile, '--state-dir', this.stateDirectory, '--workspace', this.workspace];
    if (this.desktopSecrets) args.push('--secrets', 'desktop');
    this.child = spawn(this.binary, args, { env: this.env, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    this.running = true;
    this.child.stdin.on('error', () => {});
    readline.createInterface({ input: this.child.stdout }).on('line', (line) => this.receive(line));
    this.child.stderr.on('data', (chunk) => this.emit('log', chunk.toString()));
    this.child.on('error', (error) => this.fail(error));
    this.child.on('exit', (code, signal) => {
      this.running = false;
      this.fail(new Error(`otto-engine exited (${signal ?? code})`));
      this.emit('exit', { code, signal });
    });
    return this.call('environment.getCapabilities');
  }

  /** The shared host RPC (OttoRPCContracts), the same surface paired phones use. */
  call(method, parameters) {
    const id = crypto.randomUUID().toUpperCase();
    const request = { id, protocolVersion: PROTOCOL_VERSION, method };
    if (parameters !== undefined) request.parameters = parameters;
    return this.transmit(id, method, { token: this.token, request });
  }

  /** Owner-only desktop surfaces (Home, Documents) served by otto-engine's DesktopAPI. */
  desktop(method, params) {
    const id = crypto.randomUUID().toUpperCase();
    return this.transmit(id, method, { token: this.token, desktop: { id, method, params: params ?? {} } });
  }

  transmit(id, method, envelope) {
    if (!this.running) return Promise.reject(new Error('The Otto engine is not running'));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`The Otto engine did not answer ${method}`));
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify(envelope) + '\n');
    });
  }

  /** Streams an event to the engine (microphone audio, WebSocket frames). */
  event(kind, payload) {
    if (!this.running) return;
    this.child.stdin.write(JSON.stringify({ token: this.token, hostEvent: { kind, payload } }) + '\n');
  }

  /** Answers a host call from the engine with a result, or an error message. */
  reply(id, result, error) {
    if (!this.running) return;
    const hostReply = error ? { id, error: String(error) } : { id, result: result ?? null };
    this.child.stdin.write(JSON.stringify({ token: this.token, hostReply }) + '\n');
  }

  receive(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      this.emit('log', `unparseable engine output: ${line.slice(0, 200)}`);
      return;
    }
    // The engine asking the desktop to act (run a page script, take a screenshot), and events.
    if (message.host) {
      this.emit('host', message.host);
      return;
    }
    if (message.event) {
      this.emit('event', message.event);
      return;
    }
    if (!message.id) {
      this.emit('log', `engine error: ${message.error?.message ?? line.slice(0, 200)}`);
      return;
    }
    const waiter = this.pending.get(message.id.toUpperCase());
    if (!waiter) return;
    this.pending.delete(message.id.toUpperCase());
    clearTimeout(waiter.timer);
    if (message.error) {
      const error = new Error(message.error.message || message.error.code || 'Engine error');
      error.code = message.error.code;
      waiter.reject(error);
    } else {
      waiter.resolve(message.result);
    }
  }

  // ---- Chat surface (OttoHostRuntime) ---------------------------------------------------

  bots() {
    return this.call('bot.list');
  }

  threads() {
    return this.call('thread.list').then((output) => output.threads);
  }

  startThread(botProfileID, initialMessage) {
    const parameters = { botProfileID };
    if (initialMessage) parameters.initialMessage = initialMessage;
    return this.call('thread.start', parameters);
  }

  snapshot(threadID) {
    return this.call('thread.getSnapshot', { threadID });
  }

  events(threadID, afterSequence, limit = 200) {
    return this.call('thread.events', { threadID, afterSequence, limit });
  }

  send(threadID, body) {
    return this.call('message.send', { threadID, clientMessageID: crypto.randomUUID().toUpperCase(), body });
  }

  stopRun(threadID, runID) {
    return this.call('run.stop', { threadID, runID });
  }

  interruptRun(threadID, runID) {
    return this.call('run.interrupt', { threadID, runID });
  }

  approval(threadID) {
    return this.call('approval.get', { threadID }).then((output) => output.request ?? null);
  }

  respondToApproval(threadID, request, decision) {
    return this.call('approval.respond', { threadID, requestID: request.requestID, nonce: request.nonce, decision });
  }

  fail(error) {
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer);
      reject(error);
    }
    this.pending.clear();
  }

  /** Resolves once the engine has saved its state and exited (Windows keeps files locked until then). */
  stop() {
    const child = this.child;
    if (!child || child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
    const exited = new Promise((resolve) => child.once('exit', resolve));
    this.dispose();
    return exited;
  }

  /** Closing stdin lets the engine save its state and exit; it is killed only if it lingers. */
  dispose() {
    if (!this.running) return;
    this.running = false;
    this.fail(new Error('The Otto engine was stopped'));
    const child = this.child;
    child.stdin.end();
    const timer = setTimeout(() => child.kill(), 3000);
    child.once('exit', () => clearTimeout(timer));
  }
}

module.exports = { EngineClient };
