'use strict';

// Settings → Website accounts: sites your bots may use with your own sign-in (the Mac's Website
// Accounts). You sign in once, privately, in a separate window; bots then act in that signed-in
// session but never see your password and cannot leave the site.
const WebsiteAccounts = (() => {
  let accounts = [];
  let container = null;
  let hooks = { onError: () => {}, bots: () => [] };
  let poll = null;

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  };

  async function call(method, params) {
    try {
      accounts = await window.otto.desktop(method, params);
    } catch (error) {
      hooks.onError(error);
    }
    render();
  }

  const host = (origin) => {
    try {
      return new URL(origin).host;
    } catch {
      return origin;
    }
  };

  function render() {
    if (!container) return;
    container.replaceChildren();
    container.append(el('div', 'overline', 'Website accounts'));
    container.append(el('p', 'muted small', 'Sites your bots may use with your sign-in. You sign in privately; bots never see your password and stay on that site.'));
    const bots = hooks.bots();
    for (const account of accounts) {
      const row = el('div', 'setting-row website-account');
      row.dataset.origin = account.origin;
      const text = el('div', 'setting-text');
      const who = account.allBots ? 'All bots' : account.botIDs.map((id) => bots.find((bot) => bot.id === id)?.name).filter(Boolean).join(', ') || 'No bots yet';
      text.append(el('strong', '', host(account.origin)), el('span', 'muted small', `${account.signedIn ? 'Signed in' : 'Not signed in'} · ${who}`));
      const actions = el('div', 'setting-actions');
      const signIn = el('button', account.signedIn ? 'ghost small-button' : 'primary small-button', account.signedIn ? 'Sign in again' : 'Sign in');
      signIn.classList.add('account-sign-in');
      signIn.addEventListener('click', () => {
        call('accounts.login', { id: account.id });
        watch();
      });
      const remove = el('button', 'ghost small-button', 'Disconnect');
      remove.addEventListener('click', () => {
        if (confirm(`Disconnect ${host(account.origin)}? Bots lose access and the saved sign-in is removed.`)) call('accounts.disconnect', { id: account.id });
      });
      actions.append(signIn, remove);
      row.append(text, actions);
      container.append(row);
    }
    const form = el('form', 'website-account-add');
    const origin = el('input');
    origin.id = 'website-account-origin';
    origin.placeholder = 'https://example.com';
    origin.setAttribute('aria-label', 'Website address');
    const scope = el('select');
    scope.setAttribute('aria-label', 'Which bots');
    scope.append(new Option('All bots', 'all'));
    for (const bot of bots) scope.append(new Option(bot.name, bot.id));
    const add = el('button', 'primary small-button', 'Add website');
    form.append(origin, scope, add);
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const value = origin.value.trim();
      if (!value) return;
      const address = /^https?:\/\//i.test(value) ? value : `https://${value}`;
      call('accounts.create', scope.value === 'all' ? { origin: address, allBots: true } : { origin: address, botIDs: [scope.value] });
    });
    container.append(form);
  }

  /** While a sign-in window is open, show when it finishes. */
  function watch() {
    clearInterval(poll);
    let rounds = 0;
    poll = setInterval(async () => {
      rounds += 1;
      if (!container?.isConnected || rounds > 300) return clearInterval(poll);
      const next = await window.otto.desktop('accounts.list').catch(() => null);
      if (next && JSON.stringify(next) !== JSON.stringify(accounts)) {
        accounts = next;
        render();
      }
    }, 1000);
  }

  async function section() {
    container = el('section', 'settings-website-accounts');
    try {
      accounts = await window.otto.desktop('accounts.list');
    } catch {
      accounts = [];
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
