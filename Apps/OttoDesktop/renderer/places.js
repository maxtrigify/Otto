'use strict';

// Automations, Activity and Files & notes: the Mac app's Chat places backed by otto-engine.
const Places = (() => {
  const $ = (id) => document.getElementById(id);
  let onError = () => {};
  let openLink = () => {};
  let onOpenNote = () => {};

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  };

  const when = (value) => {
    if (!value) return '';
    const date = new Date(value);
    const minutes = Math.round((Date.now() - date.getTime()) / 60000);
    if (minutes < 1) return 'just now';
    if (minutes < 60) return `${minutes}m ago`;
    if (minutes < 60 * 24) return `${Math.round(minutes / 60)}h ago`;
    return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  };

  const empty = (title, detail) => {
    const box = el('div', 'place-empty');
    box.append(el('strong', '', title), el('span', '', detail));
    return box;
  };

  // ---- Automations ---------------------------------------------------------------------------

  let automations = null;

  async function automationsCall(method, params) {
    try {
      automations = await window.otto.desktop(method, params);
      renderAutomations();
    } catch (error) {
      onError(error);
    }
  }

  function renderAutomations() {
    const body = $('automations-body');
    body.replaceChildren();
    if (!automations) return;
    if (!automations.automations.length) {
      body.append(empty('No automations yet', 'Ask a bot to do something on a schedule, or add one here.'));
    } else {
      const list = el('div', 'card place-list');
      for (const automation of automations.automations) {
        const row = el('div', 'place-row automation-row');
        row.dataset.id = automation.id;
        row.append(el('span', `dot ${automation.enabled ? 'running' : 'idle'}`));
        const text = el('div', 'place-text');
        text.append(el('strong', '', automation.name));
        const detail = [automation.trigger, automation.lastFiredAt ? `Last ran ${when(automation.lastFiredAt)}` : 'Not run yet'];
        text.append(el('span', 'muted small', detail.join(' · ')));
        if (automation.lastError) text.append(el('span', 'error small', automation.lastError));
        row.append(text);

        const actions = el('div', 'place-actions');
        const run = el('button', 'soft-button', 'Run now');
        run.addEventListener('click', async () => {
          run.disabled = true;
          run.textContent = 'Running…';
          await automationsCall('automations.runNow', { id: automation.id });
        });
        const toggle = el('button', `switch ${automation.enabled ? 'on' : ''}`.trim());
        toggle.setAttribute('role', 'switch');
        toggle.setAttribute('aria-checked', String(automation.enabled));
        toggle.title = automation.enabled ? 'Pause' : 'Turn on';
        toggle.addEventListener('click', () => automationsCall('automations.setEnabled', { id: automation.id, enabled: !automation.enabled }));
        const remove = el('button', 'tiny dismiss', '×');
        remove.title = 'Delete automation';
        remove.addEventListener('click', () => {
          if (confirm(`Delete “${automation.name}”?`)) automationsCall('automations.delete', { id: automation.id });
        });
        actions.append(run, toggle, remove);
        row.append(actions);
        list.append(row);
      }
      body.append(list);
    }

    body.append(el('div', 'overline', 'Recent runs'));
    if (!automations.runs.length) {
      body.append(el('p', 'muted small', 'Runs show up here as automations fire.'));
    } else {
      const names = new Map(automations.automations.map((item) => [item.id, item.name]));
      const runs = el('div');
      for (const run of automations.runs) {
        const row = el('div', 'list-row');
        row.append(el('span', '', names.get(run.routineID) || 'Removed automation'));
        row.append(el('span', `run-outcome ${run.outcome}`, run.outcome.replace('_', ' ')));
        row.append(el('span', 'muted small', when(run.firedAt)));
        runs.append(row);
      }
      body.append(runs);
    }
  }

  async function loadAutomations() {
    automations = null;
    await automationsCall('automations.list');
  }

  function openAutomationForm() {
    const dialog = $('automation-dialog');
    $('automation-form').reset();
    syncScheduleFields();
    dialog.showModal();
  }

  /** The Mac editor's friendly schedules (AutomationSchedule), as the cron it stores. */
  function scheduleCron() {
    const [hour, minute] = ($('automation-time').value || '09:00').split(':').map(Number);
    switch ($('automation-frequency').value) {
      case 'hourly': return `${minute} * * * *`;
      case 'daily': return `${minute} ${hour} * * *`;
      case 'weekly': return `${minute} ${hour} * * ${$('automation-weekday').value}`;
      default: return `${minute} ${hour} * * 1-5`;
    }
  }

  function syncScheduleFields() {
    const frequency = $('automation-frequency').value;
    $('automation-weekday-label').hidden = frequency !== 'weekly';
  }

  async function submitAutomation() {
    const name = $('automation-name').value.trim();
    const instruction = $('automation-instruction').value.trim();
    if (!name || !instruction) return;
    await automationsCall('automations.create', { name, instruction, cron: scheduleCron(), enabled: true });
  }

  // ---- Activity ------------------------------------------------------------------------------

  async function loadActivity() {
    const body = $('activity-body');
    try {
      const snapshot = await window.otto.desktop('activity.snapshot');
      body.replaceChildren();
      const section = (title, items, emptyText) => {
        body.append(el('div', 'overline', items.length ? `${title} · ${items.length}` : title));
        if (!items.length) {
          body.append(el('p', 'muted small', emptyText));
          return;
        }
        const list = el('div', 'card place-list');
        for (const item of items) {
          const row = el('button', 'place-row activity-row');
          row.append(el('span', `dot ${item.state === 'needs_user' || item.state === 'needsUser' ? 'attention' : 'running'}`));
          const text = el('div', 'place-text');
          text.append(el('strong', '', item.title));
          text.append(el('span', 'muted small', [item.detail, when(item.updatedAt)].filter(Boolean).join(' · ')));
          row.append(text);
          row.addEventListener('click', () => openLink(item));
          list.append(row);
        }
        body.append(list);
      };
      section('Needs you', snapshot.needsYou, 'Nothing is waiting on you.');
      section('Working now', snapshot.active, 'No bots are working right now.');
    } catch (error) {
      onError(error);
    }
  }

  // ---- Files & notes -------------------------------------------------------------------------

  let note = null;
  let noteTimer = null;

  async function loadFiles() {
    const body = $('files-body');
    try {
      const notes = await window.otto.desktop('files.list');
      body.replaceChildren();
      if (!notes.length) {
        body.append(empty('No notes yet', 'Markdown notes in this workspace folder show up here.'));
        return;
      }
      const list = el('div', 'card place-list');
      for (const item of notes) {
        const row = el('button', 'place-row file-row');
        row.dataset.path = item.path;
        row.append(Icons.icon('doc.text', 15));
        const text = el('div', 'place-text');
        text.append(el('strong', '', item.title));
        const folder = item.path.replaceAll('\\', '/').split('/').slice(0, -1).join('/');
        text.append(el('span', 'muted small', [folder || 'Workspace', when(item.modifiedAt)].join(' · ')));
        row.append(text);
        row.addEventListener('click', () => openNote(item.path));
        list.append(row);
      }
      body.append(list);
    } catch (error) {
      onError(error);
    }
  }

  async function openNote(path) {
    try {
      note = await window.otto.desktop('files.read', { path });
      $('note-title').textContent = path.replaceAll('\\', '/').split('/').pop().replace(/\.(md|markdown|txt)$/i, '');
      $('note-status').textContent = '';
      $('note-input').value = note.text;
      showNote(false);
      onOpenNote();
    } catch (error) {
      onError(error);
    }
  }

  function showNote(editing) {
    $('note-input').hidden = !editing;
    $('note-preview').hidden = editing;
    $('note-edit').textContent = editing ? 'Done' : 'Edit';
    if (!editing) $('note-preview').innerHTML = Markdown.render($('note-input').value);
    else $('note-input').focus();
  }

  async function saveNote() {
    if (!note) return;
    clearTimeout(noteTimer);
    noteTimer = null;
    const text = $('note-input').value;
    if (text === note.text) return;
    try {
      $('note-status').textContent = 'Saving…';
      note = await window.otto.desktop('files.save', { path: note.path, text });
      $('note-status').textContent = 'Saved';
    } catch (error) {
      $('note-status').textContent = 'Not saved';
      onError(error);
    }
  }

  async function closeNote() {
    if (note) await saveNote();
    note = null;
  }

  function wire() {
    $('new-automation').addEventListener('click', openAutomationForm);
    $('automation-frequency').addEventListener('change', syncScheduleFields);
    $('automation-form').addEventListener('submit', (event) => {
      if (event.submitter?.value === 'create') submitAutomation();
    });
    $('note-edit').addEventListener('click', () => showNote($('note-preview').hidden === false));
    $('note-input').addEventListener('input', () => {
      $('note-status').textContent = 'Edited';
      clearTimeout(noteTimer);
      noteTimer = setTimeout(saveNote, 800);
    });
  }

  return {
    wire,
    loadAutomations,
    loadActivity,
    loadFiles,
    closeNote,
    get noteOpen() {
      return Boolean(note);
    },
    set onError(listener) {
      onError = listener;
    },
    set onOpenNote(listener) {
      onOpenNote = listener;
    },
    set onOpenActivity(listener) {
      openLink = listener;
    },
  };
})();
