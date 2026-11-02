'use strict';

// Dashboards: named pages of live cards (Revenue, Socials, My week) that a bot builds and
// automations keep fresh, as on the Mac (DashboardsView).
const Dashboards = (() => {
  const $ = (id) => document.getElementById(id);
  const STORAGE = 'otto.dashboards.selected';
  let snapshot = null;
  let editing = false;
  let timer = null;
  let hooks = { onError: () => {}, bots: () => [], ask: async () => {}, hire: () => {} };
  /** Automation names, for "Updated … · Morning digest" under cards an automation fills. */
  let automationNames = new Map();

  const examples = [
    ['person.2', 'Socials: my followers on LinkedIn, Reddit and Substack, with the trend'],
    ['chart.bar', "Revenue: this month's payments and MRR from Stripe"],
    ['calendar', 'My week: meetings per day and my free focus time'],
    ['tray', 'Inbox: unread email by sender and what needs a reply'],
  ];

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  };

  /** A small naming dialog (Electron has no window.prompt). Resolves to the name or null. */
  function askName(title, initial = '') {
    const dialog = $('name-dialog');
    $('name-dialog-title').textContent = title;
    $('name-dialog-input').value = initial;
    dialog.showModal();
    $('name-dialog-input').select();
    return new Promise((resolve) => {
      dialog.addEventListener(
        'close',
        () => resolve(dialog.returnValue === 'save' ? $('name-dialog-input').value.trim() || null : null),
        { once: true },
      );
    });
  }

  const selected = () => {
    if (!snapshot?.dashboards.length) return null;
    const id = localStorage.getItem(STORAGE);
    return snapshot.dashboards.find((dashboard) => dashboard.id === id) || snapshot.dashboards[0];
  };
  const cardsOn = (dashboard) => snapshot.cards.filter((card) => card.dashboardID === dashboard.id);

  async function call(method, params) {
    try {
      snapshot = await window.otto.desktop(method, params);
      render();
      return true;
    } catch (error) {
      hooks.onError(error);
      return false;
    }
  }

  /** "Socials: my followers…" names a dashboard Socials; otherwise its first three words. */
  function nameFrom(request) {
    const trimmed = request.trim();
    const colon = trimmed.indexOf(':');
    if (colon > 0 && colon <= 30) return trimmed.slice(0, colon).trim();
    return trimmed.split(/\s+/).slice(0, 3).join(' ').replace(/[^\p{L}\p{N} '’-]/gu, '').replace(/^\w/, (c) => c.toUpperCase());
  }

  /** The bot that builds cards: the one picked in the prompt bar, else the first. */
  function askBar(placeholder, onAsk) {
    const form = el('form', 'composer ask-bar');
    form.append(Icons.icon('sparkles', 15, 'ask-icon'));
    const input = el('input');
    input.placeholder = placeholder;
    input.setAttribute('aria-label', placeholder);
    const bots = hooks.bots();
    const picker = el('select', 'ask-bot');
    picker.setAttribute('aria-label', 'Which bot builds it');
    for (const bot of bots) {
      const option = el('option', '', bot.name);
      option.value = bot.id;
      picker.append(option);
    }
    const remembered = localStorage.getItem('otto.dashboards.bot');
    if (bots.some((bot) => bot.id === remembered)) picker.value = remembered;
    picker.addEventListener('change', () => localStorage.setItem('otto.dashboards.bot', picker.value));
    const send = el('button', 'send');
    send.type = 'submit';
    send.setAttribute('aria-label', 'Ask');
    send.append(Icons.icon('arrow.up', 14));
    input.addEventListener('input', () => send.classList.toggle('ready', Boolean(input.value.trim())));
    if (bots.length) form.append(input, picker, send);
    else {
      const hire = el('button', 'text-button', 'Hire a bot to build dashboards');
      hire.type = 'button';
      hire.addEventListener('click', () => hooks.hire());
      form.append(input, hire);
      input.disabled = true;
    }
    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      const request = input.value.trim();
      if (!request || !picker.value) return;
      input.value = '';
      send.classList.remove('ready');
      await onAsk(request, picker.value);
    });
    return form;
  }

  async function ask(dashboard, request, botID) {
    const bot = hooks.bots().find((candidate) => candidate.id === botID);
    const message = `On my Otto dashboard “${dashboard.name}”, ${request}\n\nBuild it as cards on that dashboard with Otto's dashboard tools, and say where each number comes from.`;
    try {
      await hooks.ask(botID, message);
      hooks.toast?.(`${bot?.name || 'Your bot'} is building it. Cards appear here as they're ready.`);
      startRefreshing();
    } catch (error) {
      hooks.onError(error);
    }
  }

  function render() {
    const body = $('dashboards-body');
    body.replaceChildren();
    if (!snapshot) return;
    const dashboard = selected();
    if (!dashboard) {
      body.append(emptyState());
      return;
    }

    const tabs = el('div', 'dashboard-tabs');
    for (const item of snapshot.dashboards) {
      const tab = el('button', `dashboard-tab ${item.id === dashboard.id ? 'active' : ''}`.trim());
      tab.append(Icons.icon('chart.bar', 12), el('span', '', item.name), el('span', 'micro', String(cardsOn(item).length)));
      tab.addEventListener('click', () => {
        localStorage.setItem(STORAGE, item.id);
        editing = false;
        render();
      });
      tabs.append(tab);
    }
    body.append(tabs);

    const cards = cardsOn(dashboard);
    const head = el('div', 'dashboard-head');
    head.append(el('h2', '', dashboard.name));
    const actions = el('div', 'dashboard-actions');
    if (cards.length) {
      const edit = el('button', `pill-button ${editing ? 'active' : ''}`.trim());
      edit.id = 'dashboard-edit';
      edit.append(Icons.icon(editing ? 'checkmark' : 'paintpalette', 13), el('span', '', editing ? 'Done' : 'Edit'));
      edit.title = editing ? 'Finish arranging' : 'Arrange cards and pick colours';
      edit.addEventListener('click', () => {
        editing = !editing;
        render();
      });
      actions.append(edit);
    }
    const rename = el('button', 'tiny', '');
    rename.append(Icons.icon('pencil', 13));
    rename.title = 'Rename dashboard';
    rename.addEventListener('click', async () => {
      const name = await askName('Rename dashboard', dashboard.name);
      if (name) call('dashboards.rename', { id: dashboard.id, name });
    });
    const remove = el('button', 'tiny', '');
    remove.append(Icons.icon('trash', 13));
    remove.title = 'Delete dashboard';
    remove.addEventListener('click', () => {
      if (confirm(`Delete “${dashboard.name}” and its ${cards.length} card${cards.length === 1 ? '' : 's'}?`)) {
        call('dashboards.delete', { id: dashboard.id });
      }
    });
    actions.append(rename, remove);
    head.append(actions);
    body.append(head);

    if (editing) body.append(appearance(dashboard));
    else body.append(askBar(`Add a chart, number or list to ${dashboard.name}…`, (request, botID) => ask(dashboard, request, botID)));

    if (!cards.length) {
      const empty = el('div', 'dashboard-empty');
      empty.append(
        el('strong', '', 'Nothing here yet'),
        el('span', '', 'Ask for what you want to see, e.g. “daily signups this month as a line chart” or “top 5 customers by revenue”. Your bot finds the data with your connected apps and builds the cards.'),
      );
      body.append(empty);
      return;
    }
    const grid = el('div', 'dashboard-grid');
    for (const card of cards) {
      grid.append(
        Cards.render(card, {
          accent: dashboard.accent,
          cardStyle: dashboard.cardStyle,
          automationName: card.automationID ? automationNames.get(card.automationID) : null,
          editing,
          onEdit: (change) => call('cards.setLook', { id: card.id, ...change }),
          onMove: (offset) => call('cards.move', { id: card.id, offset }),
          onRemove: () => call('cards.remove', { id: card.id }),
        }),
      );
    }
    body.append(grid);
  }

  /** The page's look while editing: accent colour and card style. */
  function appearance(dashboard) {
    const panel = el('div', 'dashboard-look');
    panel.append(el('p', 'card-muted', 'Pick each card’s size and colour on the card. Arrows move a card.'));
    const row = el('div', 'look-row');
    const accent = el('div', 'look-group');
    accent.append(el('span', 'micro', 'ACCENT'));
    const colors = el('div', 'swatches');
    const theme = el('button', `swatch none ${dashboard.accent ? '' : 'active'}`.trim());
    theme.title = 'Theme colour';
    theme.addEventListener('click', () => call('dashboards.setLook', { id: dashboard.id, accent: '' }));
    colors.append(theme);
    for (const [name, value] of Object.entries(Cards.swatches)) {
      const swatch = el('button', `swatch ${dashboard.accent === name ? 'active' : ''}`.trim());
      swatch.style.background = value;
      swatch.title = name[0].toUpperCase() + name.slice(1);
      swatch.addEventListener('click', () => call('dashboards.setLook', { id: dashboard.id, accent: name }));
      colors.append(swatch);
    }
    accent.append(colors);
    const style = el('div', 'look-group');
    style.append(el('span', 'micro', 'CARDS'));
    const styles = el('div', 'segmented');
    for (const value of ['frosted', 'smoked', 'solid']) {
      const button = el('button', (dashboard.cardStyle || 'smoked') === value ? 'active' : '', value[0].toUpperCase() + value.slice(1));
      button.addEventListener('click', () => call('dashboards.setLook', { id: dashboard.id, cardStyle: value }));
      styles.append(button);
    }
    style.append(styles);
    row.append(accent, style);
    panel.append(row);
    return panel;
  }

  function emptyState() {
    const box = el('div', 'dashboards-empty');
    box.append(el('h2', 'serif', 'Describe a dashboard and a bot builds it'));
    box.append(
      askBar('e.g. Revenue: this month’s payments and MRR from Stripe', async (request, botID) => {
        const name = nameFrom(request) || 'Dashboard';
        const existing = snapshot.dashboards.find((item) => item.name.toLowerCase() === name.toLowerCase());
        if (!existing && !(await call('dashboards.create', { name }))) return;
        const dashboard = snapshot.dashboards.find((item) => item.name.toLowerCase() === name.toLowerCase());
        localStorage.setItem(STORAGE, dashboard.id);
        render();
        await ask(dashboard, request.includes(':') ? request.slice(request.indexOf(':') + 1).trim() : request, botID);
      }),
    );
    const ideas = el('div', 'dashboard-examples');
    for (const [icon, text] of examples) {
      const idea = el('button', 'dashboard-example');
      idea.append(Icons.icon(icon, 14), el('span', '', text));
      idea.addEventListener('click', () => {
        const input = box.querySelector('.ask-bar input');
        input.value = text;
        input.dispatchEvent(new Event('input'));
        input.focus();
      });
      ideas.append(idea);
    }
    box.append(ideas);
    return box;
  }

  function startRefreshing() {
    stopRefreshing();
    timer = setInterval(async () => {
      if ($('dashboards').hidden) return stopRefreshing();
      if (editing) return;
      try {
        const next = await window.otto.desktop('dashboards.snapshot');
        if (JSON.stringify(next) !== JSON.stringify(snapshot)) {
          snapshot = next;
          render();
        }
      } catch {}
    }, 4000);
  }

  function stopRefreshing() {
    clearInterval(timer);
    timer = null;
  }

  async function load() {
    editing = false;
    try {
      const automations = await window.otto.desktop('automations.list');
      automationNames = new Map(automations.automations.map((item) => [item.id, item.name]));
    } catch {}
    if (await call('dashboards.snapshot')) startRefreshing();
  }

  async function newDashboard() {
    const name = await askName('New dashboard');
    if (!name || !(await call('dashboards.create', { name }))) return;
    const created = snapshot.dashboards.find((item) => item.name === name);
    if (created) localStorage.setItem(STORAGE, created.id);
    editing = false;
    render();
  }

  return {
    load,
    newDashboard,
    stop: stopRefreshing,
    configure(next) {
      hooks = { ...hooks, ...next };
    },
  };
})();
