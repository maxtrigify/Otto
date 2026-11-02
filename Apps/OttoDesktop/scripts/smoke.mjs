// Launches the real desktop app, starts a Terminal chat, runs a command and screenshots it.
// usage: OTTOD_PATH=... node scripts/smoke.mjs <workspace> <output-directory>
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const electron = require('electron');
const [workspace, outputDirectory] = process.argv.slice(2);
const port = 9333;
fs.mkdirSync(outputDirectory, { recursive: true });
// A note for Files & notes to find.
fs.mkdirSync(path.join(workspace, 'Notes'), { recursive: true });
fs.writeFileSync(path.join(workspace, 'Notes', 'Smoke note.md'), '# Smoke note\n\nWritten by the desktop smoke test.\n');

// CI Linux runners cannot set up Chromium's user-namespace sandbox; the app itself keeps it.
const linuxCI = process.platform === 'linux' && process.env.CI ? ['--no-sandbox'] : [];
const app = spawn(electron, ['.', `--remote-debugging-port=${port}`, ...linuxCI], {
  cwd: path.join(path.dirname(fileURLToPath(import.meta.url)), '..'),
  env: { ...process.env, OTTO_DESKTOP_WORKSPACE: workspace },
  stdio: 'inherit',
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
let socket;
for (let attempt = 0; attempt < 60 && !socket; attempt += 1) {
  try {
    const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
    const page = targets.find((target) => target.type === 'page');
    if (page) socket = new WebSocket(page.webSocketDebuggerUrl);
  } catch {}
  if (!socket) await sleep(500);
}
if (!socket) throw new Error('the desktop window never opened');
await new Promise((resolve) => socket.addEventListener('open', resolve));

let nextID = 1;
const waiting = new Map();
const pageErrors = [];
socket.addEventListener('message', ({ data }) => {
  const message = JSON.parse(data);
  if (message.method === 'Runtime.exceptionThrown') {
    const details = message.params.exceptionDetails;
    pageErrors.push(details.exception?.description || details.text);
  }
  waiting.get(message.id)?.(message);
  waiting.delete(message.id);
});
const call = (method, params = {}) =>
  new Promise((resolve) => {
    const id = nextID++;
    waiting.set(id, resolve);
    socket.send(JSON.stringify({ id, method, params }));
  });
const evaluate = async (expression) =>
  (await call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })).result?.result?.value;
const shot = async (name) => {
  const result = await call('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(outputDirectory, name), Buffer.from(result.result.data, 'base64'));
};
const type = async (text) => {
  for (const character of text) {
    await call('Input.dispatchKeyEvent', { type: 'keyDown', key: character, text: character, unmodifiedText: character });
    await call('Input.dispatchKeyEvent', { type: 'keyUp', key: character });
  }
  const enter = { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 };
  await call('Input.dispatchKeyEvent', { type: 'keyDown', ...enter, text: '\r', unmodifiedText: '\r' });
  await call('Input.dispatchKeyEvent', { type: 'keyUp', ...enter });
};

let failure = null;
await call('Runtime.enable');
// Opens a rail place by its label and waits for its page to render without errors.
const visit = async (label, pageID, ready) => {
  const clicked = await evaluate(`(() => {
    const row = [...document.querySelectorAll('#places .rail-row')].find((candidate) => candidate.textContent.trim() === ${JSON.stringify(label)});
    if (!row) return false;
    row.click();
    return true;
  })()`);
  if (!clicked) throw new Error(`no rail row for ${label}`);
  let ok = false;
  for (let attempt = 0; attempt < 20 && !ok; attempt += 1) {
    await sleep(300);
    ok = await evaluate(`!document.getElementById(${JSON.stringify(pageID)}).hidden && (${ready})`);
  }
  const toast = await evaluate(`document.getElementById('toast').hidden ? '' : document.getElementById('toast').textContent`);
  await shot(`place-${pageID}.png`);
  console.log(`${label}: ${ok ? 'ok' : 'NOT RENDERED'}${toast ? ` (toast: ${toast})` : ''}`);
  if (!ok) throw new Error(`${label} did not render`);
  if (toast) throw new Error(`${label} showed an error: ${toast}`);
};
try {
  const engineLine = `appState && appState.daemon ? 'Engine ' + appState.daemon.version + ' · ' + appState.platform : 'offline'`;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    if ((await evaluate(engineLine))?.startsWith('Engine ')) break;
    await sleep(500);
  }
  const engine = await evaluate(engineLine);
  console.log(`engine: ${engine}`);
  await shot('1-welcome.png');
  if (!engine?.startsWith('Engine ')) throw new Error(`engine did not start: ${engine}`);
  if (process.env.OTTO_ENGINE_PATH) {
    // With the engine Otto Desktop lands on Home; New chat then offers bots.
    for (let attempt = 0; attempt < 20 && (await evaluate(`document.getElementById('home-surface').hidden`)); attempt += 1) {
      await sleep(500);
    }
    const home = await evaluate(`document.getElementById('home-surface').hidden ? null : document.querySelector('.home-greeting')?.textContent`);
    console.log(`home: ${home ?? 'missing'}`);
    if (!home) throw new Error('Home did not come up with the engine');
    await shot('0-home.png');
    await evaluate(`document.getElementById('surface-chat').click(); document.getElementById('new-chat').click()`);
    await sleep(500);
    const composer = await evaluate(`!document.getElementById('welcome-composer').hidden`);
    console.log(`chat engine: ${composer ? 'available' : 'missing'}`);
    if (!composer) throw new Error('the chat engine did not come up');

    // Every place in the rail opens and renders.
    await visit('Documents', 'documents', `document.getElementById('documents-body').childElementCount > 0`);
    await visit('Dashboards', 'dashboards', `document.querySelector('#dashboards-body .ask-bar')`);
    await evaluate(`(() => {
      document.getElementById('new-dashboard').click();
      document.getElementById('name-dialog-input').value = 'Smoke metrics';
      document.querySelector('#name-dialog button[value=save]').click();
    })()`);
    let dashboard = null;
    for (let attempt = 0; attempt < 20 && !dashboard; attempt += 1) {
      await sleep(300);
      dashboard = await evaluate(`document.querySelector('.dashboard-head h2')?.textContent ?? null`);
    }
    console.log(`dashboard created: ${dashboard}`);
    if (dashboard !== 'Smoke metrics') throw new Error('creating a dashboard did not show it');
    // Cards normally come from a bot through otto-mcp; add one of each kind directly.
    await evaluate(`(async () => {
      const { dashboards } = await window.otto.desktop('dashboards.snapshot');
      const dashboardID = dashboards[0].id;
      await window.otto.desktop('cards.add', { dashboardID, title: 'Followers', style: 'metrics', rows: [{ label: 'LinkedIn', value: '12,480', history: [12000, 12200, 12480] }, { label: 'Substack', value: '3.1k' }] });
      await window.otto.desktop('cards.add', { dashboardID, title: 'Signups', style: 'line', rows: [{ label: 'Mon', value: '4' }, { label: 'Tue', value: '9' }, { label: 'Wed', value: '7' }, { label: 'Thu', value: '12' }] });
      await window.otto.desktop('cards.add', { dashboardID, title: 'Revenue by plan', style: 'bar', rows: [{ label: 'Pro', value: '$4,200' }, { label: 'Team', value: '$8,900' }] });
      await window.otto.desktop('cards.add', { dashboardID, title: 'Next up', style: 'list', rows: [{ label: 'Ship Otto Desktop', detail: 'Windows and Linux', value: 'Fri' }] });
    })()`);
    await visit('Dashboards', 'dashboards', `document.querySelectorAll('#dashboards-body .data-card').length === 4`);
    const drawn = await evaluate(`({
      metrics: document.querySelectorAll('.metric').length,
      sparklines: document.querySelectorAll('.sparkline').length,
      lines: document.querySelectorAll('.card-chart path').length,
      bars: document.querySelectorAll('.card-chart rect.bar').length,
      rows: document.querySelectorAll('.card-list-row').length,
    })`);
    console.log(`dashboard cards: ${JSON.stringify(drawn)}`);
    if (drawn.metrics !== 2 || drawn.sparklines !== 1 || drawn.lines < 2 || drawn.bars !== 2 || drawn.rows !== 1) {
      throw new Error(`dashboard cards did not draw: ${JSON.stringify(drawn)}`);
    }
    await evaluate(`document.getElementById('dashboard-edit').click()`);
    await sleep(300);
    await evaluate(`document.querySelector('.data-card .segmented button:nth-child(2)').click()`);
    let widened = false;
    for (let attempt = 0; attempt < 20 && !widened; attempt += 1) {
      await sleep(300);
      widened = await evaluate(`Boolean(document.querySelector('.data-card.width-wide'))`);
    }
    await shot('place-dashboards-editing.png');
    if (!widened) throw new Error('making a card wide did not apply');
    await evaluate(`document.getElementById('dashboard-edit').click()`);
    await sleep(300);
    await shot('place-dashboards.png');

    await visit('Automations', 'automations', `document.querySelector('#automations-body .overline')`);
    await evaluate(`(() => {
      document.getElementById('new-automation').click();
      document.getElementById('automation-name').value = 'Smoke digest';
      document.getElementById('automation-instruction').value = 'Say hello';
      document.querySelector('#automation-form button[value=create]').click();
    })()`);
    let automation = null;
    for (let attempt = 0; attempt < 20 && !automation; attempt += 1) {
      await sleep(300);
      automation = await evaluate(`document.querySelector('.automation-row strong')?.textContent ?? null`);
    }
    await shot('place-automations-created.png');
    console.log(`automation created: ${automation}`);
    if (automation !== 'Smoke digest') throw new Error('creating an automation did not show it');
    await evaluate(`document.querySelector('.automation-row .switch').click()`);
    await sleep(800);
    const paused = await evaluate(`document.querySelector('.automation-row .switch').getAttribute('aria-checked')`);
    if (paused !== 'false') throw new Error(`pausing the automation failed: ${paused}`);

    await visit('Activity', 'activity', `document.querySelector('#activity-body .overline')`);
    await visit('Files & notes', 'files', `document.querySelector('#files-body .file-row')`);
    await evaluate(`document.querySelector('#files-body .file-row').click()`);
    let heading = null;
    for (let attempt = 0; attempt < 20 && !heading; attempt += 1) {
      await sleep(300);
      heading = await evaluate(`document.getElementById('note').hidden ? null : document.querySelector('#note-preview :is(h1,h2,h3)')?.textContent ?? null`);
    }
    await shot('place-note.png');
    console.log(`note: ${heading}`);
    if (heading !== 'Smoke note') throw new Error('the note did not open');
    await visit('Memory', 'memory', `document.querySelector('#memory-body .overline')`);
    await evaluate(`document.getElementById('nav-settings').click()`);
    await sleep(500);
    if (await evaluate(`document.getElementById('settings').hidden`)) throw new Error('Settings did not open');
    await shot('place-settings.png');
    if (pageErrors.length) throw new Error(`page errors:\n${pageErrors.join('\n')}`);
  }

  await evaluate(`document.getElementById('surface-chat').click(); document.getElementById('add-terminal').click()`);
  await sleep(4000);
  await evaluate(`document.querySelector('.terminal-host:not([hidden]) textarea').focus()`);
  const marker = 'otto-smoke-ok';
  await type(process.platform === 'win32' ? `Write-Output "${marker} on $([Environment]::OSVersion.VersionString)"` : `echo "${marker} on $(uname -s)"`);
  let text = '';
  for (let attempt = 0; attempt < 40 && !text.includes(`${marker} on`); attempt += 1) {
    await sleep(500);
    // Read xterm's buffer, not the DOM: Chromium defers painting while the window is in the background.
    text = await evaluate(`(() => {
      const session = [...Terminals.sessions.values()].find((candidate) => !candidate.element.hidden);
      const buffer = session.term.buffer.active;
      const lines = [];
      for (let index = 0; index < buffer.length; index += 1) lines.push(buffer.getLine(index)?.translateToString(true) ?? '');
      return lines.join('\\n');
    })()`);
  }
  await shot('2-terminal.png');
  console.log(text.split('\n').filter((line) => line.trim()).slice(-6).join('\n'));
  if (!text.includes(`${marker} on`)) throw new Error('the command output never appeared');

  await evaluate(`document.getElementById('stop-button').click()`);
  await sleep(1500);
  const meta = await evaluate(`document.getElementById('stage-meta').textContent`);
  await shot('3-stopped.png');
  console.log(`after stop: ${meta}`);
  if (meta !== 'Stopped' && !/^(Finished|Exited)/.test(meta)) throw new Error(`session did not stop: ${meta}`);
  if (pageErrors.length) throw new Error(`page errors:\n${pageErrors.join('\n')}`);
} catch (error) {
  failure = error;
} finally {
  socket.close();
  app.kill();
}
if (failure) {
  console.error(failure.message);
  process.exit(1);
}
console.log('desktop smoke test passed');
process.exit(0);
