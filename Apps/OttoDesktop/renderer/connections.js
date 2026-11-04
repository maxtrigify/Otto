'use strict';

// Settings → Connect apps: Gmail (and Calendar) through Google's own sign-in in the person's
// browser, as on the Mac. Tokens stay with the engine in the OS keychain; nothing passes
// through a chat.
const Connections = (() => {
  let status = null;
  let container = null;
  let hooks = { onError: () => {} };
  let poll = null;

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  };

  async function call(method, params) {
    try {
      status = await window.otto.desktop(method, params);
    } catch (error) {
      hooks.onError(error);
    }
    render();
  }

  function render() {
    if (!container) return;
    container.replaceChildren();
    container.append(el('div', 'overline', 'Connect apps'));
    if (!status) {
      container.append(el('p', 'muted small', 'Connections start with the chat engine.'));
      return;
    }
    const card = el('div', 'setting-row connection-row');
    const text = el('div', 'setting-text');
    text.append(el('strong', '', 'Gmail'), el('span', 'muted small', 'Search your inbox, read conversations and prepare replies.'));
    const actions = el('div', 'setting-actions');
    card.append(text, actions);
    container.append(card);

    if (!status.configured) {
      actions.append(setupButton());
    } else if (status.connecting) {
      text.append(el('span', 'muted small', 'Finish signing in with Google in your browser…'));
      const cancel = el('button', 'ghost small-button', 'Cancel');
      cancel.addEventListener('click', () => call('connections.google.cancel'));
      actions.append(cancel);
    } else {
      const sending = el('label', 'connection-option');
      const sendBox = el('input');
      sendBox.type = 'checkbox';
      sendBox.id = 'gmail-allow-sending';
      sending.append(sendBox, el('span', '', 'Allow saving drafts and sending email'));
      const calendar = el('label', 'connection-option');
      const calendarBox = el('input');
      calendarBox.type = 'checkbox';
      calendarBox.id = 'gmail-allow-calendar';
      calendar.append(calendarBox, el('span', '', 'Include Google Calendar'));
      text.append(sending, calendar);
      const connect = el('button', 'primary small-button', status.accounts.length ? 'Add account' : 'Connect');
      connect.id = 'gmail-connect';
      connect.addEventListener('click', () => {
        status.connecting = true;
        render();
        watch();
        call('connections.google.connect', { allowSending: sendBox.checked, allowCalendar: calendarBox.checked });
      });
      actions.append(connect);
    }
    if (status.error) container.append(el('p', 'error small', status.error));

    for (const account of status.accounts) {
      const row = el('div', 'setting-row');
      const label = el('div', 'setting-text');
      const can = ['read', account.canSend && 'send', account.canReadCalendar && 'calendar'].filter(Boolean).join(' · ');
      label.append(el('strong', '', account.email), el('span', 'muted small', account.needsReconnect ? 'Needs reconnecting' : `${can} · ${account.shared ? 'available across supported agents' : 'only where you allow it'}`));
      const buttons = el('div', 'setting-actions');
      if (account.needsReconnect) {
        const again = el('button', 'primary small-button', 'Reconnect');
        again.addEventListener('click', () => call('connections.google.connect', { reconnect: account.id, allowSending: account.canSend, allowCalendar: account.canReadCalendar }));
        buttons.append(again);
      }
      const share = el('button', 'ghost small-button', account.shared ? 'Stop sharing' : 'Share with agents');
      share.addEventListener('click', () => call('connections.google.share', { id: account.id, shared: !account.shared }));
      const remove = el('button', 'ghost small-button', 'Disconnect');
      remove.addEventListener('click', () => {
        if (confirm(`Disconnect ${account.email}? All Otto agents will lose access to this account.`)) {
          call('connections.google.disconnect', { id: account.id });
        }
      });
      buttons.append(share, remove);
      row.append(label, buttons);
      container.append(row);
    }
    container.append(el('p', 'muted small', 'Credentials stay in your system keychain. Passwords and Google tokens never belong in chat.'));
  }

  /** When no Google client is built in, the person can bring their own (as on the Mac). */
  function setupButton() {
    const button = el('button', 'ghost small-button', 'Set up Google sign-in');
    button.addEventListener('click', () => {
      const form = el('form', 'google-setup');
      const id = el('input');
      id.placeholder = 'Google OAuth client ID';
      id.setAttribute('aria-label', 'Google OAuth client ID');
      const secret = el('input');
      secret.type = 'password';
      secret.placeholder = 'Client secret, if required';
      secret.setAttribute('aria-label', 'Client secret');
      const save = el('button', 'primary small-button', 'Save setup');
      form.append(id, secret, save);
      form.addEventListener('submit', (event) => {
        event.preventDefault();
        call('connections.google.configure', { clientID: id.value.trim(), clientSecret: secret.value || null });
      });
      container.append(form);
      id.focus();
    });
    return button;
  }

  /** While the browser sign-in is open, follow its progress. */
  function watch() {
    clearInterval(poll);
    poll = setInterval(async () => {
      if (!container?.isConnected) return clearInterval(poll);
      const next = await window.otto.desktop('connections.google').catch(() => null);
      if (!next) return;
      const changed = JSON.stringify(next) !== JSON.stringify(status);
      status = next;
      if (changed) render();
      if (!next.connecting) clearInterval(poll);
    }, 1000);
  }

  async function section() {
    container = el('section', 'settings-connections');
    try {
      status = await window.otto.desktop('connections.google');
    } catch {
      status = null;
    }
    render();
    return container;
  }

  return {
    section,
    configure(next) {
      hooks = { ...hooks, ...next };
    },
  };
})();
