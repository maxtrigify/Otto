// Website accounts' private pages (the Mac's WebsiteAccountDriver views). Each account is its
// own Chromium session that never leaves the account's origin; scripts from the engine run in
// an isolated world the page cannot see or tamper with (WebKit's .defaultClient world on the
// Mac). The person signs in in a separate window; bots never see that window or its input.
'use strict';

const path = require('node:path');
const { BrowserWindow, WebContentsView, session: electronSession } = require('electron');

const ISOLATED_WORLD = 1987;

/** The Mac driver's rule: https (or the test fixture's origin), same host and port, no userinfo. */
function allowed(url, origins) {
  let target;
  try {
    target = new URL(url);
  } catch {
    return false;
  }
  if (target.username || target.password) return false;
  return origins.some((origin) => {
    const expected = new URL(origin);
    if (target.protocol !== expected.protocol) return false;
    if (target.protocol !== 'https:' && !(target.protocol === 'http:' && expected.hostname === '127.0.0.1')) return false;
    const port = (address) => address.port || (address.protocol === 'https:' ? '443' : '80');
    return target.hostname.toLowerCase() === expected.hostname.toLowerCase() && port(target) === port(expected);
  });
}

class AccountHost {
  constructor({ window, engine }) {
    this.window = window;
    this.engine = engine;
    this.accounts = new Map(); // accountID -> { view, origins, failed, signIn }
  }

  handles(method) {
    return method.startsWith('account.');
  }

  async handle(method, params) {
    switch (method) {
      case 'account.open':
        this.open(params);
        return true;
      case 'account.load': {
        const entry = this.require(params.accountID);
        entry.failed = false;
        if (!allowed(params.url, entry.origins)) throw new Error('Not this account’s website');
        entry.view.webContents.loadURL(params.url).catch(() => {});
        return true;
      }
      case 'account.eval': {
        const entry = this.require(params.accountID);
        const names = Object.keys(params.arguments ?? {});
        if (names.some((name) => !/^[A-Za-z_$][\w$]*$/.test(name))) throw new Error('Bad argument name');
        // The body runs as an async function with its arguments as named parameters, like
        // WKWebView.callAsyncJavaScript, in a world separate from the page's own scripts.
        const code = `(async ({${names.join(',')}}) => { ${params.body}\n })(${JSON.stringify(params.arguments ?? {})})`;
        const value = await entry.view.webContents.executeJavaScriptInIsolatedWorld(ISOLATED_WORLD, [{ code }], true);
        return value === undefined ? null : value;
      }
      default:
        throw new Error(`Unknown host call ${method}`);
    }
  }

  event(kind, payload) {
    if (kind === 'account.show') this.show(payload);
    else if (kind === 'account.hide') this.hide(payload.accountID);
    else if (kind === 'account.close') this.close(payload.accountID);
    else if (kind === 'account.finished') this.finished(payload);
  }

  require(accountID) {
    const entry = this.accounts.get(accountID);
    if (!entry) throw new Error('That website account is not open');
    return entry;
  }

  open({ accountID, origin, allowOrigin }) {
    if (this.accounts.has(accountID)) return;
    const origins = [...new Set([origin, allowOrigin].filter(Boolean))];
    const partition = `persist:otto-account-${accountID}`;
    const view = new WebContentsView({
      webPreferences: { partition, sandbox: true, contextIsolation: true, nodeIntegration: false, backgroundThrottling: false },
    });
    view.setBackgroundColor('#ffffff');
    view.setVisible(false);
    view.setBounds({ x: 0, y: 0, width: 1100, height: 760 });
    this.window.contentView.addChildView(view);
    const entry = { view, origins, failed: false, signIn: null };
    this.accounts.set(accountID, entry);
    const contents = view.webContents;
    const report = () =>
      this.engine()?.event('account.state', {
        accountID,
        url: contents.getURL() || null,
        isLoading: contents.isLoading(),
        failed: entry.failed,
      });
    // Never leave the account's origin, in any frame; a blocked main-frame move fails the load.
    const guard = (event, url, isMainFrame = true) => {
      if (allowed(url, origins)) return;
      event.preventDefault();
      if (isMainFrame) {
        entry.failed = true;
        report();
      }
    };
    contents.on('will-navigate', (event) => guard(event, event.url, event.isMainFrame));
    contents.on('will-redirect', (event) => guard(event, event.url, event.isMainFrame));
    contents.on('will-frame-navigate', (event) => guard(event, event.url, event.isMainFrame));
    contents.setWindowOpenHandler(() => ({ action: 'deny' }));
    contents.on('did-start-loading', report);
    contents.on('did-stop-loading', report);
    contents.on('did-navigate', report);
    contents.on('did-navigate-in-page', report);
    contents.on('did-fail-load', (_event, code, _description, _url, isMainFrame) => {
      if (isMainFrame && code !== -3) {
        entry.failed = true;
        report();
      }
    });
    // Private sessions get no extra powers (camera, notifications, downloads).
    const sessionHandle = electronSession.fromPartition(partition);
    sessionHandle.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
    sessionHandle.on('will-download', (event) => event.preventDefault());
  }

  /** The private sign-in window: the account's page under a bar with Done and Cancel. */
  show({ accountID, origin }) {
    const entry = this.accounts.get(accountID);
    if (!entry) return;
    if (entry.signIn && !entry.signIn.isDestroyed()) {
      entry.signIn.focus();
      return;
    }
    const signIn = new BrowserWindow({
      width: 1000,
      height: 760,
      parent: this.window,
      title: `Sign in privately · ${new URL(origin).host}`,
      autoHideMenuBar: true,
      backgroundColor: '#101113',
      webPreferences: { preload: path.join(__dirname, 'signin-preload.js'), contextIsolation: true, sandbox: true },
    });
    entry.signIn = signIn;
    signIn.loadFile(path.join(__dirname, '..', 'renderer', 'signin.html'), { query: { origin, accountID } });
    const BAR = 64;
    const layout = () => {
      const [width, height] = signIn.getContentSize();
      entry.view.setBounds({ x: 0, y: BAR, width, height: Math.max(1, height - BAR) });
    };
    this.window.contentView.removeChildView(entry.view);
    signIn.contentView.addChildView(entry.view);
    entry.view.setVisible(true);
    layout();
    signIn.on('resize', layout);
    signIn.on('closed', () => {
      // Closing without Done cancels the sign-in.
      if (entry.signIn === signIn) {
        entry.signIn = null;
        this.engine()?.event('account.cancel', { accountID });
        this.park(entry);
      }
    });
  }

  /** The person pressed Done or Cancel in the sign-in window. */
  answer({ accountID, done }) {
    const entry = this.accounts.get(accountID);
    if (!entry?.signIn) return;
    if (done) {
      this.engine()?.event('account.done', { accountID });
    } else {
      const window = entry.signIn;
      entry.signIn = null;
      this.engine()?.event('account.cancel', { accountID });
      this.park(entry);
      window.close();
    }
  }

  finished({ accountID, error }) {
    const entry = this.accounts.get(accountID);
    if (!entry?.signIn) return;
    if (error) {
      entry.signIn.webContents.send('signin:error', error);
      return;
    }
    const window = entry.signIn;
    entry.signIn = null;
    this.park(entry);
    window.close();
  }

  /** Back into the main window, hidden: bots keep using the signed-in session. */
  park(entry) {
    for (const parent of BrowserWindow.getAllWindows()) {
      if (parent !== this.window && !parent.isDestroyed()) parent.contentView.removeChildView(entry.view);
    }
    if (!this.window.isDestroyed()) {
      this.window.contentView.addChildView(entry.view);
      entry.view.setVisible(false);
      entry.view.setBounds({ x: 0, y: 0, width: 1100, height: 760 });
    }
  }

  hide(accountID) {
    const entry = this.accounts.get(accountID);
    if (entry && !entry.signIn) entry.view.setVisible(false);
  }

  close(accountID) {
    const entry = this.accounts.get(accountID);
    if (!entry) return;
    this.accounts.delete(accountID);
    if (entry.signIn && !entry.signIn.isDestroyed()) {
      entry.signIn.removeAllListeners('closed');
      entry.signIn.close();
    }
    for (const window of BrowserWindow.getAllWindows()) window.contentView.removeChildView(entry.view);
    entry.view.webContents.close();
  }

  dispose() {
    for (const accountID of [...this.accounts.keys()]) this.close(accountID);
  }
}

module.exports = { AccountHost, allowed };
