'use strict';

// Memory: About me (personal), workspace habits (operating) and the project brain.
const Memory = (() => {
  const $ = (id) => document.getElementById(id);
  let snapshot = null;
  let filter = '';
  let onError = () => {};

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  };

  async function act(method, params) {
    try {
      snapshot = await window.otto.desktop(method, params);
      render();
    } catch (error) {
      onError(error);
    }
  }

  function entryList(entries, removeMethod, emptyText) {
    const list = el('div', 'memory-list');
    if (!entries.length) list.append(el('p', 'muted small', emptyText));
    for (const entry of entries) {
      const row = el('div', 'memory-entry');
      row.append(el('span', '', entry.text));
      const meta = el('span', 'muted small', entry.source === 'user' ? 'You' : entry.source);
      const forget = el('button', 'tiny dismiss', '×');
      forget.title = 'Forget this';
      forget.addEventListener('click', () => act(removeMethod, { id: entry.id }));
      row.append(meta, forget);
      list.append(row);
    }
    return list;
  }

  function render() {
    if (!snapshot) return;
    const body = $('memory-body');
    body.replaceChildren();

    const about = el('section', 'home-section');
    about.append(el('h2', 'home-section-title', 'About me'));
    about.append(entryList(snapshot.personal, 'memory.removePersonal', 'Nothing yet. Tell Otto something about you.'));
    const form = el('form', 'add-todo');
    const input = el('input');
    input.placeholder = 'Add something Otto should remember about you…';
    input.setAttribute('aria-label', 'Add to About me');
    form.append(input);
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const text = input.value.trim();
      if (text) act('memory.addPersonal', { text });
    });
    about.append(form);
    body.append(about);

    const habits = el('section', 'home-section');
    habits.append(el('h2', 'home-section-title', 'Workspace habits'));
    habits.append(entryList(snapshot.operating, 'memory.removeOperating', 'No workspace habits yet.'));
    body.append(habits);

    const brain = el('section', 'home-section');
    const title = el('h2', 'home-section-title', 'Project brain');
    if (snapshot.brain.length) title.append(el('span', 'count', String(snapshot.brain.length)));
    brain.append(title);
    const search = el('input', 'memory-search');
    search.placeholder = 'Search the brain…';
    search.value = filter;
    search.addEventListener('input', () => {
      filter = search.value;
      renderBrain(results);
    });
    const results = el('div', 'brain-list');
    brain.append(search, results);
    body.append(brain);
    renderBrain(results);
  }

  function renderBrain(container) {
    container.replaceChildren();
    const needle = filter.trim().toLowerCase();
    const records = snapshot.brain.filter(
      (record) => !needle || `${record.title} ${record.body} ${record.tags.join(' ')}`.toLowerCase().includes(needle),
    );
    if (!records.length) {
      container.append(el('p', 'muted small', snapshot.brain.length ? 'No matches.' : 'Bots write decisions and facts here as they work.'));
      return;
    }
    for (const record of records) {
      const details = el('details', 'brain-record');
      const summary = el('summary');
      summary.append(el('span', 'brain-type', record.type), el('span', 'brain-title', record.title));
      summary.append(el('span', 'muted small', new Date(record.updatedAt).toLocaleDateString()));
      details.append(summary);
      const text = el('div', 'brain-body message assistant');
      text.innerHTML = Markdown.render(record.body);
      details.append(text);
      container.append(details);
    }
  }

  async function load() {
    try {
      snapshot = await window.otto.desktop('memory.snapshot');
      render();
    } catch (error) {
      onError(error);
    }
  }

  return {
    load,
    set onError(listener) {
      onError = listener;
    },
  };
})();
