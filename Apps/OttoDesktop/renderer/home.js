'use strict';

// Home: the same brief, reviews and cards as Otto's Home on the Mac, through otto-engine.
const Home = (() => {
  const $ = (id) => document.getElementById(id);
  let snapshot = null;
  let onError = () => {};

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  };

  function greeting() {
    const hour = new Date().getHours();
    if (hour < 5) return 'Good evening';
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  const time = (value) =>
    value ? new Date(value).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';

  function section(title, count) {
    const wrapper = el('section', 'home-section');
    const header = el('h2', 'home-section-title', title);
    if (count) header.append(el('span', 'count', String(count)));
    wrapper.append(header);
    return wrapper;
  }

  async function act(method, params) {
    try {
      snapshot = await window.otto.desktop(method, params);
      render();
    } catch (error) {
      onError(error);
    }
  }

  function reviewCard(review) {
    const card = el('div', 'review');
    const top = el('div', 'review-top');
    top.append(el('strong', '', review.title), el('span', 'muted', `from ${review.requester}`));
    card.append(top);
    const draft = el('pre', 'review-draft', review.draft);
    card.append(draft);
    if (review.afterApproval) card.append(el('p', 'muted small', `After approval: ${review.afterApproval}`));
    if (review.problem) card.append(el('p', 'error small', review.problem));
    const actions = el('div', 'review-actions');
    const reject = el('button', 'ghost', 'Reject');
    const approve = el('button', 'primary', 'Approve');
    reject.addEventListener('click', () => act('review.reject', { id: review.id }));
    approve.addEventListener('click', () => act('review.approve', { id: review.id }));
    actions.append(reject, approve);
    card.append(actions);
    return card;
  }

  function todoRow(item) {
    const row = el('label', 'todo' + (item.completedAt ? ' done' : ''));
    const box = el('input');
    box.type = 'checkbox';
    box.checked = Boolean(item.completedAt);
    box.addEventListener('change', () => act('brief.complete', { id: item.id, completed: box.checked }));
    const text = el('span', 'todo-text');
    text.append(el('span', 'todo-title', item.title));
    if (item.reason) text.append(el('span', 'muted small', item.reason));
    const dismiss = el('button', 'tiny dismiss', '×');
    dismiss.title = 'Dismiss';
    dismiss.addEventListener('click', (event) => {
      event.preventDefault();
      act('brief.dismiss', { id: item.id });
    });
    row.append(box, text, dismiss);
    return row;
  }

  function cardElement(card) {
    const box = el('div', `home-card ${card.width || 'regular'} ${card.color || ''}`);
    box.append(el('h3', '', card.title));
    if (card.text) box.append(el('p', 'card-text', card.text));
    if (card.rows?.length) {
      const list = el('ul', 'card-rows');
      for (const row of card.rows) {
        const item = el('li');
        item.append(el('span', 'row-label', row.label));
        if (row.value) item.append(el('span', 'row-value', row.value));
        if (row.detail) item.append(el('span', 'muted small row-detail', row.detail));
        list.append(item);
      }
      box.append(list);
    }
    if (card.updatedAt) box.append(el('span', 'muted small card-updated', `Updated ${new Date(card.updatedAt).toLocaleString()}`));
    return box;
  }

  function render() {
    if (!snapshot) return;
    $('home-greeting').textContent = greeting();
    const open = snapshot.todos.filter((item) => !item.completedAt).length;
    $('home-sub').textContent = [
      snapshot.profile,
      snapshot.reviews.length ? `${snapshot.reviews.length} waiting on you` : null,
      `${open} to-do${open === 1 ? '' : 's'}`,
      snapshot.completedTodayCount ? `${snapshot.completedTodayCount} done today` : null,
    ]
      .filter(Boolean)
      .join(' · ');

    const body = $('home-body');
    body.replaceChildren();

    if (snapshot.reviews.length) {
      const needs = section('Needs you', snapshot.reviews.length);
      for (const review of snapshot.reviews) needs.append(reviewCard(review));
      body.append(needs);
    }

    const todos = section('To-dos', open || undefined);
    for (const item of snapshot.todos) todos.append(todoRow(item));
    const form = el('form', 'add-todo');
    const input = el('input');
    input.placeholder = 'Add a to-do…';
    input.setAttribute('aria-label', 'Add a to-do');
    form.append(input);
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const title = input.value.trim();
      if (title) act('brief.addTodo', { title });
    });
    todos.append(form);
    body.append(todos);

    if (snapshot.events.length) {
      const events = section('Today');
      for (const item of snapshot.events) {
        const row = el('div', 'event');
        row.append(el('span', 'event-time', [time(item.time), time(item.endTime)].filter(Boolean).join('–')));
        row.append(el('span', '', item.title));
        events.append(row);
      }
      body.append(events);
    }

    if (snapshot.updates.length) {
      const updates = section('Updates');
      for (const item of snapshot.updates) {
        const row = el('div', 'update');
        row.append(el('span', 'update-title', item.title));
        if (item.reason || item.source) row.append(el('span', 'muted small', item.reason || item.source));
        updates.append(row);
      }
      body.append(updates);
    }

    if (snapshot.cards.length) {
      const cards = section('Cards');
      const grid = el('div', 'card-grid');
      for (const card of snapshot.cards) grid.append(cardElement(card));
      cards.append(grid);
      body.append(cards);
    }
  }

  async function load() {
    try {
      snapshot = await window.otto.desktop('home.snapshot');
      render();
    } catch (error) {
      onError(error);
    }
  }

  return {
    load,
    get reviewCount() {
      return snapshot?.reviews.length ?? 0;
    },
    set onError(listener) {
      onError = listener;
    },
  };
})();
