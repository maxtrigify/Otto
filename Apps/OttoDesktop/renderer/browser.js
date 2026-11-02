'use strict';

// Chat's Browser place: your own tabs at full width (ChatBrowserPlace on the Mac). The tabs are
// the engine's browser, the same one bots drive with browser.* tools, and its pages share one
// signed-in session with them. The main process draws each page over #browser-page.
const BrowserPlace = (() => {
  const $ = (id) => document.getElementById(id);
  const START = 'otto://start';
  const shortcuts = [
    ['Google', 'https://www.google.com'],
    ['Gmail', 'https://mail.google.com'],
    ['Calendar', 'https://calendar.google.com'],
    ['LinkedIn', 'https://www.linkedin.com'],
    ['GitHub', 'https://github.com'],
    ['YouTube', 'https://www.youtube.com'],
  ];
  const ideas = [
    'Summarise this page in five bullets',
    'Compare the pages in my open tabs',
    'Save the key points from this page as a document',
  ];
  let browser = null; // { nodeID, name, state }
  let visible = false;
  let editingAddress = false;
  let hooks = { onError: () => {}, bots: () => [], ask: async () => {}, hire: () => {}, toast: () => {} };

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  };
  const isPage = (url) => /^https?:\/\//i.test(url || '');
  const host = (url) => {
    try {
      return new URL(url).host.replace(/^www\./, '');
    } catch {
      return '';
    }
  };

  /** "example.com" opens the site; anything else searches, as an address bar does. */
  function destination(text) {
    const value = text.trim();
    if (!value) return null;
    if (/^https?:\/\//i.test(value)) return value;
    if (/^[\w-]+(\.[\w-]+)+(:\d+)?(\/\S*)?$/.test(value) && !/\s/.test(value)) return `https://${value}`;
    return `https://www.google.com/search?q=${encodeURIComponent(value)}`;
  }

  async function call(method, params) {
    try {
      const list = await window.otto.desktop(method, params);
      pick(list);
      return true;
    } catch (error) {
      hooks.onError(error);
      return false;
    }
  }

  function pick(list) {
    browser = list.find((item) => item.nodeID === browser?.nodeID) || list[list.length - 1] || null;
    render();
    place();
  }

  // ---- Page area ---------------------------------------------------------------------------

  /** Tells the main process where to draw the active tab, or to hide it. */
  function place() {
    if (!visible || !browser || !isPage(browser.state.url)) {
      window.otto.browserShow(browser?.nodeID ?? null, null);
      if (!visible) window.otto.browserHide();
      return;
    }
    const rect = $('browser-page').getBoundingClientRect();
    window.otto.browserShow(browser.nodeID, {
      x: Math.round(rect.left),
      y: Math.round(rect.top),
      width: Math.max(1, Math.round(rect.width)),
      height: Math.max(1, Math.round(rect.height)),
    });
  }

  // ---- Chrome ------------------------------------------------------------------------------

  function render() {
    const tabs = $('browser-tabs');
    tabs.replaceChildren();
    if (!browser) return;
    const { state } = browser;
    for (const tab of state.tabs) {
      const active = tab.id === state.activeTabID;
      const button = el('div', `browser-tab ${active ? 'active' : ''}`.trim());
      button.setAttribute('role', 'tab');
      button.setAttribute('aria-selected', String(active));
      button.title = tab.url;
      const label = isPage(tab.url) ? tab.title || host(tab.url) || 'Loading…' : 'New Tab';
      button.append(Icons.icon('globe', 12), el('span', 'browser-tab-title', label));
      const close = el('button', 'browser-tab-close', '×');
      close.title = 'Close tab';
      close.addEventListener('click', (event) => {
        event.stopPropagation();
        call('browser.closeTab', { nodeID: browser.nodeID, tabID: tab.id });
      });
      button.append(close);
      button.addEventListener('click', () => {
        if (!active) call('browser.selectTab', { nodeID: browser.nodeID, tabID: tab.id });
      });
      tabs.append(button);
    }
    const add = el('button', 'browser-new-tab');
    add.title = 'New tab';
    add.append(Icons.icon('plus', 13));
    add.addEventListener('click', () => newTab());
    tabs.append(add);

    $('browser-back').disabled = !state.canGoBack;
    $('browser-forward').disabled = !state.canGoForward;
    $('browser-reload').classList.toggle('loading', Boolean(state.isLoading));
    if (!editingAddress) $('browser-address').value = isPage(state.url) ? state.url : '';
    const agent = state.agentControlPhase;
    $('browser-agent').hidden = !agent;
    $('browser-agent').textContent = agent === 'acting' ? 'A bot is using this page' : agent ? 'A bot is reading this page' : '';
    $('browser-start').hidden = isPage(state.url);
    $('browser-error').hidden = !state.errorMessage;
    $('browser-error').textContent = state.errorMessage || '';
  }

  function renderStart() {
    const grid = $('browser-shortcuts');
    grid.replaceChildren();
    for (const [name, url] of shortcuts) {
      const tile = el('button', 'browser-shortcut');
      tile.append(el('span', 'browser-shortcut-badge', name[0]), el('span', '', name));
      tile.addEventListener('click', () => go(url));
      grid.append(tile);
    }
  }

  async function newTab() {
    if (!browser) return open('https://www.google.com');
    await call('browser.open', { url: 'https://www.google.com', nodeID: browser.nodeID });
    $('browser-address').focus();
    $('browser-address').select();
  }

  async function open(url) {
    return call('browser.open', { url });
  }

  /** Loads `url` in the current tab (or opens the browser with it). */
  async function go(url) {
    if (!browser) return open(url);
    return call('browser.navigate', { nodeID: browser.nodeID, url });
  }

  // ---- Ask about this page -----------------------------------------------------------------

  /** As on the Mac, the bot is told which page and which Otto browser, so it reads the page
   *  with the browser tools (signed in) instead of fetching a signed-out copy. */
  function askMessage(request) {
    const { state } = browser;
    const active = state.tabs.find((tab) => tab.id === state.activeTabID);
    const lines = ['The person is looking at a page in Otto Browser.'];
    if (active) lines.push(`Active tab: ${active.title || host(active.url)} — ${active.url}`);
    const others = state.tabs.filter((tab) => tab.id !== state.activeTabID && isPage(tab.url));
    if (others.length) lines.push(`Other open tabs: ${others.map((tab) => `${tab.title || host(tab.url)} — ${tab.url}`).join('; ')}`);
    lines.push(`Use the Otto browser tools with nodeID ${browser.nodeID} to read or act on it.`, '', request);
    return lines.join('\n');
  }

  function openAsk() {
    const panel = $('browser-ask');
    const bots = hooks.bots();
    panel.hidden = !panel.hidden;
    place();
    if (panel.hidden) return;
    const picker = $('browser-ask-bot');
    picker.replaceChildren();
    for (const bot of bots) {
      const option = el('option', '', bot.name);
      option.value = bot.id;
      picker.append(option);
    }
    $('browser-ask-form').hidden = !bots.length;
    $('browser-ask-hire').hidden = Boolean(bots.length);
    const list = $('browser-ask-ideas');
    list.replaceChildren();
    for (const idea of ideas) {
      const button = el('button', 'browser-idea', idea);
      button.addEventListener('click', () => ask(idea));
      list.append(button);
    }
    $('browser-ask-input').focus();
  }

  async function ask(request) {
    const botID = $('browser-ask-bot').value;
    if (!browser || !botID || !request.trim()) return;
    const bot = hooks.bots().find((candidate) => candidate.id === botID);
    try {
      await hooks.ask(botID, askMessage(request.trim()));
      $('browser-ask-input').value = '';
      $('browser-ask').hidden = true;
      place();
      hooks.toast(`${bot?.name || 'Your bot'} is on it. Its reply is in its chat.`);
    } catch (error) {
      hooks.onError(error);
    }
  }

  // ---- Lifecycle ---------------------------------------------------------------------------

  async function show() {
    visible = true;
    renderStart();
    try {
      const list = await window.otto.browserSync();
      if (!list.length) {
        browser = null;
        render();
        $('browser-start').hidden = false;
        place();
        return;
      }
      pick(list);
    } catch (error) {
      hooks.onError(error);
    }
  }

  function hide() {
    visible = false;
    $('browser-ask').hidden = true;
    window.otto.browserHide();
  }

  function wire() {
    for (const [id, icon, title] of [
      ['browser-back', 'chevron.left', 'Back'],
      ['browser-forward', 'chevron.left', 'Forward'],
      ['browser-reload', 'arrow.clockwise', 'Reload'],
      ['browser-ask-button', 'sparkles', 'Ask about this page'],
    ]) {
      $(id).append(Icons.icon(icon, 14));
      $(id).title = title;
    }
    $('browser-forward').classList.add('flip');
    $('browser-ask-button').append(el('span', '', 'Ask'));
    $('browser-back').addEventListener('click', () => browser && call('browser.back', { id: browser.nodeID }));
    $('browser-forward').addEventListener('click', () => browser && call('browser.forward', { id: browser.nodeID }));
    $('browser-reload').addEventListener('click', () => browser && call('browser.refresh', { id: browser.nodeID }));
    $('browser-ask-button').addEventListener('click', openAsk);
    $('browser-ask-hire').addEventListener('click', () => hooks.hire());
    $('browser-ask-form').addEventListener('submit', (event) => {
      event.preventDefault();
      ask($('browser-ask-input').value);
    });
    const address = $('browser-address');
    address.addEventListener('focus', () => {
      editingAddress = true;
      address.select();
    });
    address.addEventListener('blur', () => {
      editingAddress = false;
      if (browser) render();
    });
    $('browser-address-form').addEventListener('submit', (event) => {
      event.preventDefault();
      const url = destination(address.value);
      if (!url) return;
      address.blur();
      go(url);
    });
    $('browser-start-form').addEventListener('submit', (event) => {
      event.preventDefault();
      const url = destination($('browser-start-input').value);
      if (url) go(url);
    });
    window.otto.onBrowserState((list) => {
      if (!visible) return;
      pick(list);
    });
    new ResizeObserver(() => visible && place()).observe($('browser-page'));
    window.addEventListener('resize', () => visible && place());
  }

  return {
    wire,
    show,
    hide,
    go,
    configure(next) {
      hooks = { ...hooks, ...next };
    },
    get current() {
      return browser;
    },
  };
})();
