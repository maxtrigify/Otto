'use strict';

// Documents: the workspace's Word documents, Otto sheets and slides, through otto-engine.
// Word documents are editable as text (saved automatically); sheets and slides are shown read-only
// for now.
const Documents = (() => {
  const $ = (id) => document.getElementById(id);
  const KIND = {
    document: { icon: '▤', label: 'Document' },
    spreadsheet: { icon: '▦', label: 'Sheet' },
    presentation: { icon: '▭', label: 'Slides' },
  };
  let onError = () => {};
  let onOpen = () => {};
  let open = null; // { path, kind, timer, saved }

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  };

  async function list() {
    try {
      const files = await window.otto.desktop('documents.list');
      const body = $('documents-body');
      body.replaceChildren();
      if (!files.length) {
        body.append(el('p', 'empty-state', 'No documents yet. Start one, or ask a bot to write it.'));
        return;
      }
      files.sort((a, b) => new Date(b.modifiedAt) - new Date(a.modifiedAt));
      const grid = el('div', 'doc-grid');
      for (const file of files) {
        const card = el('button', `doc-card ${file.kind}`);
        card.append(el('span', 'doc-icon', KIND[file.kind]?.icon ?? '▤'));
        card.append(el('span', 'doc-title', file.title));
        card.append(
          el('span', 'muted small', `${KIND[file.kind]?.label ?? file.kind} · ${new Date(file.modifiedAt).toLocaleString()}`),
        );
        card.addEventListener('click', () => openFile(file.path));
        grid.append(card);
      }
      body.append(grid);
    } catch (error) {
      onError(error);
    }
  }

  async function create(kind) {
    const title = kind === 'document' ? 'Untitled document' : 'Untitled sheet';
    try {
      const file = await window.otto.desktop('documents.create', { kind, title: `${title} ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}` });
      await openFile(file.path);
    } catch (error) {
      onError(error);
    }
  }

  function status(text) {
    $('editor-status').textContent = text;
  }

  async function save() {
    if (!open || open.kind !== 'document') return;
    const text = $('editor-text')?.value ?? '';
    if (text === open.saved) return;
    status('Saving…');
    try {
      await window.otto.desktop('documents.saveText', { path: open.path, text });
      open.saved = text;
      status('Saved');
    } catch (error) {
      status('Not saved');
      onError(error);
    }
  }

  function renderSheet(sheet) {
    const cells = sheet.cells || {};
    let maxRow = 0;
    let maxColumn = 0;
    for (const key of Object.keys(cells)) {
      const match = key.match(/^([A-Z]+)(\d+)$/);
      if (!match) continue;
      const column = [...match[1]].reduce((total, letter) => total * 26 + letter.charCodeAt(0) - 64, 0);
      maxColumn = Math.max(maxColumn, column);
      maxRow = Math.max(maxRow, Number(match[2]));
    }
    maxRow = Math.max(maxRow, 20);
    maxColumn = Math.max(maxColumn, 8);
    const name = (index) => {
      let label = '';
      for (let value = index; value > 0; value = Math.floor((value - 1) / 26)) {
        label = String.fromCharCode(65 + ((value - 1) % 26)) + label;
      }
      return label;
    };
    const table = el('table', 'sheet');
    const head = el('tr');
    head.append(el('th', 'corner', ''));
    for (let column = 1; column <= maxColumn; column += 1) head.append(el('th', '', name(column)));
    table.append(head);
    for (let row = 1; row <= maxRow; row += 1) {
      const line = el('tr');
      line.append(el('th', '', String(row)));
      for (let column = 1; column <= maxColumn; column += 1) line.append(el('td', '', cells[`${name(column)}${row}`] ?? ''));
      table.append(line);
    }
    const wrap = el('div', 'sheet-wrap');
    wrap.append(table);
    return wrap;
  }

  function renderDeck(deck) {
    const wrap = el('div', 'deck');
    deck.slides.forEach((slide, index) => {
      const card = el('div', 'slide');
      card.append(el('span', 'muted small', `Slide ${index + 1}`));
      card.append(el('h3', '', slide.title));
      if (slide.bullets?.length) {
        const list = el('ul');
        for (const bullet of slide.bullets) list.append(el('li', '', bullet));
        card.append(list);
      }
      wrap.append(card);
    });
    if (!deck.slides.length) wrap.append(el('p', 'empty-state', 'No slides yet.'));
    return wrap;
  }

  async function openFile(path) {
    await save();
    try {
      const content = await window.otto.desktop('documents.read', { path });
      open = { path, kind: content.file.kind, saved: content.text ?? '' };
      $('editor-title').textContent = content.file.title;
      status(content.file.kind === 'document' ? 'Saved' : 'Read only here for now');
      const body = $('editor-body');
      body.replaceChildren();
      if (content.file.kind === 'document') {
        const area = el('textarea', 'doc-editor');
        area.id = 'editor-text';
        area.value = content.text ?? '';
        area.spellcheck = true;
        area.addEventListener('input', () => {
          status('Editing…');
          clearTimeout(open.timer);
          open.timer = setTimeout(save, 800);
        });
        body.append(area);
        onOpen();
        requestAnimationFrame(() => area.focus());
      } else if (content.sheet) {
        body.append(renderSheet(content.sheet));
        onOpen();
      } else if (content.deck) {
        body.append(renderDeck(content.deck));
        onOpen();
      }
    } catch (error) {
      onError(error);
    }
  }

  async function close() {
    if (open) clearTimeout(open.timer);
    await save();
    open = null;
  }

  return {
    list,
    create,
    close,
    set onError(listener) {
      onError = listener;
    },
    set onOpen(listener) {
      onOpen = listener;
    },
  };
})();
