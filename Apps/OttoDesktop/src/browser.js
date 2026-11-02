// Renders the engine's browsers (the same ones bots drive with browser.* tools) in Chromium
// views, the way the Mac app renders them with WebKit. The engine owns each browser's state;
// this follows it (navigate, back, tab changes), answers the engine's page reads and clicks,
// and reports page loads back.
'use strict';

const { WebContentsView, session: electronSession, shell } = require('electron');

const START_URL = 'otto://start';
const BLANK_URL = 'about:blank';
const PARTITION = 'persist:otto-browser';
const isPage = (url) => /^https?:\/\//i.test(url || '') || url === BLANK_URL;

class BrowserHost {
  /** `window` hosts the views; `engine()` returns the running EngineClient; `notify` updates the UI. */
  constructor({ window, engine, notify }) {
    this.window = window;
    this.engine = engine;
    this.notify = notify;
    this.browsers = new Map(); // nodeID -> { name, state, applied }
    this.views = new Map(); // tabID -> { nodeID, view }
    this.shown = null; // nodeID on screen, if the Browser place is open
    this.bounds = { x: 0, y: 0, width: 1100, height: 760 };
    this.session = electronSession.fromPartition(PARTITION);
    // Look like a normal browser to sites that sniff for Electron.
    this.session.setUserAgent(this.session.getUserAgent().replace(/\s(Electron|otto-desktop)\/\S+/gi, ''));
  }

  // ---- Engine state ----------------------------------------------------------------------

  /** A browser.state event: the engine's view of one browser after any change. */
  apply({ nodeID, name, state }) {
    const browser = this.browsers.get(nodeID) || { applied: -1 };
    browser.name = name;
    browser.state = state;
    this.browsers.set(nodeID, browser);

    // Views for tabs the engine no longer has are closed.
    const tabIDs = new Set(state.tabs.map((tab) => tab.id));
    for (const [tabID, entry] of this.views) {
      if (entry.nodeID === nodeID && !tabIDs.has(tabID)) this.destroyView(tabID);
    }
    const active = this.ensureView(nodeID, state.activeTabID, state.url);
    if (state.revision > browser.applied) {
      browser.applied = state.revision;
      const contents = active.view.webContents;
      switch (state.requestedAction) {
        case 'navigate':
          this.load(contents, state.url);
          break;
        case 'back':
          if (contents.navigationHistory.canGoBack()) contents.navigationHistory.goBack();
          break;
        case 'forward':
          if (contents.navigationHistory.canGoForward()) contents.navigationHistory.goForward();
          break;
        case 'refresh':
          contents.reload();
          break;
        case 'stop':
          contents.stop();
          break;
        default:
          break; // activateTab: the tab's live page is shown as it is
      }
    }
    this.layout();
    this.notify('browser:state', this.list());
  }

  closed({ nodeID }) {
    for (const [tabID, entry] of this.views) if (entry.nodeID === nodeID) this.destroyView(tabID);
    this.browsers.delete(nodeID);
    if (this.shown === nodeID) this.shown = null;
    this.notify('browser:state', this.list());
  }

  list() {
    return [...this.browsers.entries()].map(([nodeID, browser]) => ({ nodeID, name: browser.name, state: browser.state }));
  }

  // ---- Views -----------------------------------------------------------------------------

  ensureView(nodeID, tabID, url) {
    const existing = this.views.get(tabID);
    if (existing) return existing;
    const view = new WebContentsView({
      webPreferences: {
        partition: PARTITION,
        sandbox: true,
        contextIsolation: true,
        nodeIntegration: false,
        // Bots browse while the window is in the background; keep their pages running.
        backgroundThrottling: false,
      },
    });
    view.setBackgroundColor('#ffffff');
    view.setVisible(false);
    // Hidden tabs keep a real size so pages lay out and bots can read them.
    view.setBounds(this.bounds);
    this.window.contentView.addChildView(view);
    const entry = { nodeID, view };
    this.views.set(tabID, entry);
    this.watch(entry, tabID);
    if (isPage(url)) this.load(view.webContents, url);
    return entry;
  }

  destroyView(tabID) {
    const entry = this.views.get(tabID);
    if (!entry) return;
    this.views.delete(tabID);
    this.window.contentView.removeChildView(entry.view);
    entry.view.webContents.close();
  }

  load(contents, url) {
    if (!isPage(url)) return;
    contents.loadURL(url).catch(() => {}); // failures arrive through did-fail-load
  }

  watch({ nodeID, view }, tabID) {
    const contents = view.webContents;
    const report = (extra = {}) => this.report(nodeID, tabID, contents, extra);
    contents.on('did-start-loading', () => report({ isLoading: true }));
    contents.on('did-stop-loading', () => report({ isLoading: false }));
    contents.on('did-navigate', () => report());
    contents.on('did-navigate-in-page', () => report());
    contents.on('page-title-updated', () => report());
    contents.on('did-fail-load', (_event, code, description, _url, isMainFrame) => {
      if (isMainFrame && code !== -3) report({ isLoading: false, error: description || `Error ${code}` });
    });
    // Links that open a new window become tabs in the same browser, as on the Mac.
    contents.setWindowOpenHandler(({ url }) => {
      if (/^https?:\/\//i.test(url)) {
        this.engine()?.desktop('browser.open', { url, nodeID }).catch(() => {});
      } else if (/^(mailto|tel):/i.test(url)) {
        shell.openExternal(url);
      }
      return { action: 'deny' };
    });
  }

  report(nodeID, tabID, contents, { isLoading = contents.isLoading(), error = null } = {}) {
    const browser = this.browsers.get(nodeID);
    const url = contents.getURL();
    if (!browser || !url) return;
    this.engine()
      ?.desktop('browser.reportLoaded', {
        nodeID,
        tabID,
        url,
        title: contents.getTitle() || null,
        canGoBack: contents.navigationHistory.canGoBack(),
        canGoForward: contents.navigationHistory.canGoForward(),
        isLoading,
        error,
        revision: browser.state.revision,
      })
      .catch(() => {});
  }

  /** Shows `nodeID`'s active tab in `bounds` (the Browser place's page area), or hides all. */
  show(nodeID, bounds) {
    this.shown = nodeID;
    if (bounds) this.bounds = bounds;
    this.layout();
  }

  layout() {
    const active = this.shown && this.browsers.get(this.shown)?.state?.activeTabID;
    for (const [tabID, entry] of this.views) {
      entry.view.setBounds(this.bounds);
      entry.visible = tabID === active && isPage(this.browsers.get(entry.nodeID)?.state?.url);
      entry.view.setVisible(entry.visible);
    }
  }

  activeEntry(nodeID) {
    const tabID = this.browsers.get(nodeID)?.state?.activeTabID;
    const entry = tabID && this.views.get(tabID);
    if (!entry) throw new Error('That browser tab is not open');
    return entry;
  }

  activeContents(nodeID) {
    return this.activeEntry(nodeID).view.webContents;
  }

  // ---- Host calls from the engine (BrowserRuntime's renderer handlers) --------------------

  async handle(method, params) {
    switch (method) {
      case 'browser.prepare': {
        this.apply(params);
        const contents = this.activeContents(params.nodeID);
        const deadline = Date.now() + 15_000;
        while ((contents.isLoading() || !contents.getURL()) && Date.now() < deadline) {
          await new Promise((resolve) => setTimeout(resolve, 100));
        }
        return true;
      }
      case 'browser.eval': {
        const value = await this.activeContents(params.nodeID).executeJavaScript(params.script, true);
        return typeof value === 'string' ? value : JSON.stringify(value);
      }
      case 'browser.click': {
        // A real (trusted) mouse press, as the Mac does, which some sites require. Input goes
        // through the DevTools protocol, which reaches the page even when the window is not
        // focused. If that is unavailable the engine falls back to scripted events.
        const entry = this.activeEntry(params.nodeID);
        try {
          // Pages in a hidden tab or a background window ignore pointer input.
          const shown = await entry.view.webContents.executeJavaScript('document.visibilityState', true);
          if (!entry.visible || shown !== 'visible') return false;
          const input = this.debuggerFor(entry.view.webContents);
          const point = { x: params.x, y: params.y, button: 'left', clickCount: 1 };
          await input.sendCommand('Input.dispatchMouseEvent', { type: 'mouseMoved', x: params.x, y: params.y });
          await input.sendCommand('Input.dispatchMouseEvent', { type: 'mousePressed', ...point });
          await input.sendCommand('Input.dispatchMouseEvent', { type: 'mouseReleased', ...point });
          return true;
        } catch {
          return false;
        }
      }
      case 'browser.capture': {
        const contents = this.activeContents(params.nodeID);
        try {
          const image = await contents.capturePage(undefined, { stayHidden: true });
          if (!image.isEmpty()) {
            const size = image.getSize();
            return { png: image.toPNG().toString('base64'), width: size.width, height: size.height };
          }
        } catch {
          // A hidden tab or background window has no display surface; render it instead.
        }
        const shot = await this.debuggerFor(contents).sendCommand('Page.captureScreenshot', { format: 'png' });
        const size = await contents.executeJavaScript('[innerWidth, innerHeight, devicePixelRatio]', true);
        return { png: shot.data, width: Math.round(size[0] * size[2]), height: Math.round(size[1] * size[2]) };
      }
      default:
        throw new Error(`Unknown host call ${method}`);
    }
  }

  debuggerFor(contents) {
    if (!contents.debugger.isAttached()) contents.debugger.attach('1.3');
    return contents.debugger;
  }

  dispose() {
    for (const tabID of [...this.views.keys()]) this.destroyView(tabID);
    this.browsers.clear();
  }
}

module.exports = { BrowserHost, START_URL, BLANK_URL };
