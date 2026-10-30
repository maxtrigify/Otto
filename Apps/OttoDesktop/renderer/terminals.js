'use strict';

// Raw terminal sessions through ottod: each session keeps its own xterm so scrollback survives
// switching away and back.
const Terminals = (() => {
  const sessions = new Map(); // sessionID -> { name, term, fit, element, status, startedAt, exitText }
  const pendingEvents = new Map(); // events that raced ahead of the launch response
  const $ = (id) => document.getElementById(id);
  let onChange = () => {};

  const theme = {
    background: '#0d0e10',
    foreground: '#e7e5e0',
    cursor: '#f2c879',
    cursorAccent: '#0d0e10',
    selectionBackground: '#f2c87944',
    black: '#1b1d21', brightBlack: '#5c6068',
    red: '#ec7b74', brightRed: '#f59b95',
    green: '#9fcf8a', brightGreen: '#b9e3a6',
    yellow: '#f2c879', brightYellow: '#f8dba3',
    blue: '#7fa8e8', brightBlue: '#a3c2f1',
    magenta: '#c49be8', brightMagenta: '#d8b9f2',
    cyan: '#78c9c4', brightCyan: '#9ddcd8',
    white: '#d8d6d0', brightWhite: '#ffffff',
  };

  function decode(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return bytes;
  }

  function createTerminal() {
    const element = document.createElement('div');
    element.className = 'terminal-host';
    $('terminals').append(element);
    const term = new Terminal({
      theme,
      fontFamily: '"Cascadia Code", "SF Mono", Menlo, Consolas, "DejaVu Sans Mono", monospace',
      fontSize: 13,
      lineHeight: 1.2,
      cursorBlink: true,
      scrollback: 10000,
    });
    const fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    term.open(element);
    return { term, fit, element };
  }

  async function launch(agentID) {
    const view = createTerminal();
    view.fit.fit();
    try {
      const result = await window.otto.launch(agentID, view.term.cols || 120, view.term.rows || 36);
      const session = { ...view, name: result.name, status: 'running', startedAt: new Date() };
      sessions.set(result.sessionID, session);
      view.term.onData((text) => {
        if (session.status === 'running') window.otto.input(result.sessionID, text).catch(() => {});
      });
      view.term.onResize(({ cols, rows }) => {
        if (session.status === 'running') window.otto.resize(result.sessionID, cols, rows).catch(() => {});
      });
      const early = pendingEvents.get(result.sessionID) || [];
      pendingEvents.delete(result.sessionID);
      early.forEach(handleEvent);
      return result.sessionID;
    } catch (error) {
      view.term.dispose();
      view.element.remove();
      throw error;
    }
  }

  function handleEvent(event) {
    const session = sessions.get(event.sessionID);
    if (!session) {
      if (event.sessionID) pendingEvents.set(event.sessionID, [...(pendingEvents.get(event.sessionID) || []), event]);
      return;
    }
    if (event.kind === 'session.output') {
      session.term.write(decode(event.payload.data));
      return;
    }
    if ((event.kind === 'session.exited' || event.kind === 'session.stopped') && session.status === 'running') {
      session.status = 'ended';
      const code = event.payload?.exitCode;
      session.exitText = event.kind === 'session.stopped' ? 'Stopped' : code === 0 ? 'Finished' : `Exited (${code})`;
      session.term.write(`\r\n\x1b[2m— ${session.exitText} —\x1b[0m\r\n`);
      onChange();
    }
  }

  function show(sessionID) {
    const session = sessions.get(sessionID);
    for (const [id, other] of sessions) other.element.hidden = id !== sessionID;
    if (!session) return;
    $('stage-name').textContent = session.name;
    $('stage-dot').className = `dot ${session.status}`;
    $('stage-meta').textContent = session.status === 'running' ? '' : session.exitText || 'Ended';
    $('stop-button').hidden = session.status !== 'running';
    requestAnimationFrame(() => {
      session.fit.fit();
      session.term.focus();
    });
  }

  function fitActive(sessionID) {
    sessions.get(sessionID)?.fit.fit();
  }

  function endAll() {
    for (const session of sessions.values()) session.status = 'ended';
  }

  function clear() {
    for (const session of sessions.values()) {
      session.term.dispose();
      session.element.remove();
    }
    sessions.clear();
  }

  return {
    sessions,
    launch,
    handleEvent,
    show,
    fitActive,
    endAll,
    clear,
    set onChange(listener) {
      onChange = listener;
    },
  };
})();
