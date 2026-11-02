'use strict';

// Home: the Mac app's PersonalHomeView over the theme artwork — greeting, composer, reviews,
// to-dos, the day, updates, cards and agents — through otto-engine.
const Home = (() => {
  const $ = (id) => document.getElementById(id);
  let snapshot = null;
  let hooks = { onError() {}, bots: () => [], userName: () => '', startChat() {}, openBot() {}, go() {} };
  let draft = '';
  let target = null; // bot id for the composer
  let addingTodo = false;

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  };

  function greeting() {
    const hour = new Date().getHours();
    const part = hour < 5 ? 'Good evening' : hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
    const name = hooks.userName();
    return name ? `${part}, ${name}` : part;
  }

  const time = (value) => (value ? new Date(value).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '');

  function ago(value) {
    const seconds = Math.max(0, Math.round((Date.now() - new Date(value)) / 1000));
    if (seconds < 60) return 'just now';
    if (seconds < 3600) return `${Math.round(seconds / 60)} minutes ago`;
    if (seconds < 86400) return `${Math.round(seconds / 3600)} hours ago`;
    return new Date(value).toLocaleDateString([], { day: 'numeric', month: 'short' });
  }

  async function act(method, params) {
    try {
      snapshot = await window.otto.desktop(method, params);
      render();
    } catch (error) {
      hooks.onError(error);
    }
  }

  function hero() {
    const box = el('div', 'home-hero');
    box.append(el('div', 'home-date', new Date().toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' })));
    const open = snapshot.todos.filter((item) => !item.completedAt).length;
    const quiet = !open && !snapshot.reviews.length && !snapshot.events.length;
    box.append(el('h1', 'home-greeting', quiet ? "What's on your mind?" : greeting()));
    const parts = [];
    if (snapshot.reviews.length) parts.push(`${snapshot.reviews.length} for your review`);
    if (open) parts.push(`${open} to-do${open === 1 ? '' : 's'}`);
    if (snapshot.events.length) parts.push(`${snapshot.events.length} on today`);
    box.append(
      el('p', 'home-summary', quiet ? 'A place for your ideas, your people, and whatever comes next.' : parts.join(' · ')),
    );
    return box;
  }

  function composer() {
    const form = el('form', 'composer home-composer');
    const input = el('textarea');
    input.rows = 1;
    input.placeholder = 'Ask, make, or explore something…';
    input.value = draft;
    input.setAttribute('aria-label', 'Ask Otto');
    const row = el('div', 'composer-row');
    const picker = el('label', 'picker');
    picker.append(Icons.icon('text.bubble', 15));
    const select = el('select');
    const bots = hooks.bots();
    for (const bot of bots) {
      const option = el('option', '', bot.name);
      option.value = bot.id;
      select.append(option);
    }
    const hire = el('option', '', bots.length ? 'Hire a bot…' : 'Hire a bot to start');
    hire.value = '__hire__';
    select.append(hire);
    if (target && bots.some((bot) => bot.id === target)) select.value = target;
    else if (bots[0]) target = select.value = bots[0].id;
    else select.value = '__hire__';
    select.addEventListener('change', () => {
      if (select.value === '__hire__') {
        hooks.hire();
        select.value = target ?? '__hire__';
      } else {
        target = select.value;
        renderProvider();
      }
    });
    picker.append(select, Icons.icon('chevron.down', 12));
    const right = el('div', 'composer-row');
    const provider = el('span', 'picker');
    const renderProvider = () => {
      const bot = bots.find((candidate) => candidate.id === target);
      provider.textContent = bot ? bot.provider : '';
    };
    renderProvider();
    const send = el('button', 'send');
    send.type = 'submit';
    send.setAttribute('aria-label', 'Send');
    send.append(Icons.icon('arrow.up', 15));
    const update = () => send.classList.toggle('ready', Boolean(input.value.trim()));
    input.addEventListener('input', () => {
      draft = input.value;
      update();
    });
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        form.requestSubmit();
      }
    });
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const text = input.value.trim();
      if (!text) return;
      if (!target) return hooks.hire();
      draft = '';
      hooks.startChat(target, text);
    });
    update();
    right.append(provider, send);
    row.append(picker, right);
    form.append(input, row);
    return form;
  }

  function quickActions() {
    const row = el('div', 'quick-actions');
    const add = (icon, label, run) => {
      const button = el('button');
      button.type = 'button';
      button.append(Icons.icon(icon, 13), el('span', '', label));
      button.addEventListener('click', run);
      row.append(button);
    };
    add('plus.circle', 'To-do', () => {
      addingTodo = true;
      render();
      document.querySelector('.add-todo input')?.focus();
    });
    add('doc.richtext', 'Documents', () => hooks.go('documents'));
    add('brain', 'Memory', () => hooks.go('memory'));
    add('terminal', 'Terminal', () => hooks.go('terminal'));
    return row;
  }

  function reviewCard(review) {
    const card = el('div', 'card review');
    const top = el('div', 'review-top');
    const heading = el('div', 'review-heading');
    heading.append(el('div', 'review-title', review.title));
    heading.append(el('div', 'review-meta', `${review.requester} · ${ago(review.createdAt)}`));
    top.append(heading, el('span', 'needs-you', 'NEEDS YOU'));
    card.append(top);
    card.append(el('div', 'review-draft', review.draft));
    if (review.afterApproval) {
      const line = el('div', 'review-line');
      line.append(Icons.icon('arrow.turn', 13), el('span', '', `When you approve: ${review.afterApproval}`));
      card.append(line);
    }
    for (const note of review.notes || []) {
      const line = el('div', 'review-line');
      line.append(Icons.icon(note.author === 'person' ? 'person' : 'sparkles', 13), el('span', '', note.text));
      card.append(line);
    }
    if (review.problem) card.append(el('div', 'review-line', review.problem));
    const actions = el('div', 'review-actions');
    const button = (icon, label, run) => {
      const node = el('button', 'small-action');
      node.append(Icons.icon(icon, 12), el('span', '', label));
      node.addEventListener('click', run);
      actions.append(node);
    };
    button('checkmark', 'Approve', () => act('review.approve', { id: review.id }));
    button('text.bubble', 'Comment', () => {
      const text = window.prompt('Comment on this draft');
      if (text?.trim()) act('review.comment', { id: review.id, text: text.trim() });
    });
    button('xmark', 'Reject', () => act('review.reject', { id: review.id }));
    card.append(actions);
    return card;
  }

  function cardShell(icon, title, count, onAdd) {
    const card = el('div', 'card');
    const header = el('div', 'card-header');
    if (icon) header.append(Icons.icon(icon, 16));
    const h3 = el('h3', '', title);
    if (count) h3.append(el('span', 'count', String(count)));
    header.append(h3, el('span', 'grow'));
    if (onAdd) {
      const add = el('button', 'card-add');
      add.title = `Add to ${title}`;
      add.append(Icons.icon('plus', 14));
      add.addEventListener('click', onAdd);
      header.append(add);
    }
    const body = el('div', 'card-body');
    card.append(header, body);
    return { card, body };
  }

  function todosCard() {
    const open = snapshot.todos.filter((item) => !item.completedAt);
    const { card, body } = cardShell(null, 'Top to-dos', open.length || undefined, () => {
      addingTodo = true;
      render();
      document.querySelector('.add-todo input')?.focus();
    });
    for (const item of snapshot.todos) {
      const row = el('div', 'todo');
      const check = el('button', 'todo-check' + (item.completedAt ? ' done' : ''));
      check.title = item.completedAt ? 'Mark as not done' : 'Mark as done';
      if (item.completedAt) check.append(Icons.icon('checkmark', 11));
      check.addEventListener('click', () => act('brief.complete', { id: item.id, completed: !item.completedAt }));
      const text = el('div', 'todo-text');
      text.append(el('span', 'todo-title', item.title));
      text.append(el('span', 'todo-source', item.source || 'You'));
      const dismiss = el('button', 'tiny todo-dismiss');
      dismiss.title = 'Dismiss';
      dismiss.append(Icons.icon('xmark', 12));
      dismiss.addEventListener('click', () => act('brief.dismiss', { id: item.id }));
      row.append(check, text, dismiss);
      body.append(row);
    }
    if (addingTodo || !snapshot.todos.length) {
      const form = el('form', 'add-todo');
      const input = el('input');
      input.placeholder = 'Add a to-do…';
      input.setAttribute('aria-label', 'Add a to-do');
      form.append(input);
      form.addEventListener('submit', (event) => {
        event.preventDefault();
        const title = input.value.trim();
        if (title) {
          addingTodo = false;
          act('brief.addTodo', { title });
        }
      });
      body.append(form);
    }
    return card;
  }

  function agentsCard() {
    const bots = hooks.bots();
    const { card, body } = cardShell('person.2', 'Your agents', undefined, () => hooks.hire());
    if (!bots.length) body.append(el('p', 'muted small', 'No bots yet. Hire one to give it a place here.'));
    for (const bot of bots) {
      const row = el('div', 'agent-row');
      const text = el('div', 'agent-text');
      text.append(el('span', 'agent-name', bot.name), el('span', 'agent-job', bot.jobTitle || bot.provider));
      const open = el('button', 'link-action', 'Open chat');
      open.addEventListener('click', () => hooks.openBot(bot));
      row.append(Icons.face(bot.name, 26), text, open);
      body.append(row);
    }
    return card;
  }

  function render() {
    if (!snapshot) return;
    const body = $('home-body');
    body.replaceChildren();
    body.append(hero(), composer(), quickActions());

    if (snapshot.reviews.length) {
      const section = el('section', 'home-section');
      const title = el('h2', 'home-section-title', 'For your review');
      title.append(el('span', 'count', String(snapshot.reviews.length)));
      section.append(title);
      for (const review of snapshot.reviews) section.append(reviewCard(review));
      body.append(section);
    }

    const brief = el('section', 'home-section');
    brief.append(todosCard());
    if (snapshot.events.length) {
      const { card, body: list } = cardShell('calendar', 'Your day', snapshot.events.length);
      for (const item of snapshot.events) {
        const row = el('div', 'event-row');
        row.append(el('span', 'event-time', [time(item.time), time(item.endTime)].filter(Boolean).join('–')), el('span', '', item.title));
        list.append(row);
      }
      brief.append(card);
    }
    if (snapshot.updates.length) {
      const { card, body: list } = cardShell('tray', 'New updates', snapshot.updates.length);
      for (const item of snapshot.updates) {
        const row = el('div', 'update-row');
        row.append(el('span', 'update-title', item.title));
        if (item.reason || item.source) row.append(el('span', 'muted small', item.reason || item.source));
        list.append(row);
      }
      brief.append(card);
    }
    body.append(brief);

    if (snapshot.cards.length) {
      const section = el('section', 'home-section');
      section.append(el('h2', 'home-section-title', 'Make it yours'));
      const grid = el('div', 'home-cards');
      for (const card of snapshot.cards) grid.append(Cards.render(card));
      section.append(grid);
      body.append(section);
    }

    const agents = el('section', 'home-section');
    agents.append(agentsCard());
    body.append(agents);
  }

  async function load() {
    try {
      snapshot = await window.otto.desktop('home.snapshot');
      render();
    } catch (error) {
      hooks.onError(error);
    }
  }

  return {
    load,
    render,
    get reviewCount() {
      return snapshot?.reviews.length ?? 0;
    },
    configure(next) {
      hooks = { ...hooks, ...next };
    },
  };
})();
