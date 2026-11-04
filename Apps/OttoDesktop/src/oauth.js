// Google sign-in for Gmail and Calendar, desktop side. Google requires the person's own browser
// (not an embedded view), so this listens once on 127.0.0.1, opens the browser at the engine's
// PKCE authorization URL and hands the engine the callback that carries its state. The engine
// keeps the PKCE secret and validates the callback itself.
'use strict';

const http = require('node:http');

class LoopbackSignIn {
  /** `open(url)` shows the URL in the person's browser (Electron's shell by default). */
  constructor({ open = (url) => require('electron').shell.openExternal(url) } = {}) {
    this.open = open;
    this.servers = new Map(); // port -> { server, waiter }
  }

  listen() {
    return new Promise((resolve, reject) => {
      const server = http.createServer((request, response) => this.receive(server, request, response));
      server.on('error', reject);
      server.listen(0, '127.0.0.1', () => {
        const { port } = server.address();
        this.servers.set(port, { server, waiter: null });
        // A sign-in that is never finished must not leave a listener behind.
        setTimeout(() => this.close(port, new Error('Google sign-in timed out')), 5 * 60_000).unref();
        resolve({ port });
      });
    });
  }

  callback({ url, state, port, timeoutSeconds = 180 }) {
    const entry = this.servers.get(port);
    if (!entry) throw new Error('The sign-in listener is gone');
    if (!/^https:\/\/accounts\.google\.com\//.test(url)) throw new Error('Not a Google sign-in address');
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.close(port, new Error('Google sign-in timed out')), timeoutSeconds * 1000);
      entry.waiter = { state, resolve, reject, timer };
      Promise.resolve(this.open(url)).catch((error) => this.close(port, error));
    });
  }

  receive(server, request, response) {
    const port = server.address().port;
    const entry = this.servers.get(port);
    const reply = (status, body) => {
      response.writeHead(status, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store', connection: 'close' });
      response.end(body);
    };
    const parsed = new URL(request.url, `http://127.0.0.1:${port}`);
    const states = parsed.searchParams.getAll('state');
    // Unsolicited or forged requests must not consume the real sign-in.
    if (request.method !== 'GET' || parsed.pathname !== '/oauth2callback' || !entry?.waiter || states.length !== 1 || states[0] !== entry.waiter.state) {
      reply(400, 'This sign-in response could not be verified.');
      return;
    }
    reply(200, 'Return to Otto to finish connecting Gmail. You can close this tab.');
    const { resolve, timer } = entry.waiter;
    clearTimeout(timer);
    this.servers.delete(port);
    server.close();
    resolve({ request: parsed.pathname + parsed.search });
  }

  close(port, error) {
    const entry = this.servers.get(port);
    if (!entry) return;
    this.servers.delete(port);
    entry.server.close();
    if (entry.waiter) {
      clearTimeout(entry.waiter.timer);
      entry.waiter.reject(error);
    }
  }

  dispose() {
    for (const port of [...this.servers.keys()]) this.close(port, new Error('Otto is closing'));
  }
}

module.exports = { LoopbackSignIn };
