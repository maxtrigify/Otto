// Launches the real desktop app, starts a Terminal chat, runs a command and screenshots it.
// usage: OTTOD_PATH=... node scripts/smoke.mjs <workspace> <output-directory>
import { spawn } from 'node:child_process';
import http from 'node:http';
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
// A fake microphone, so voice and dictation run without hardware or a permission prompt.
const fakeMedia = ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream'];
const app = spawn(electron, ['.', `--remote-debugging-port=${port}`, ...fakeMedia, ...linuxCI], {
  cwd: path.join(path.dirname(fileURLToPath(import.meta.url)), '..'),
  env: { ...process.env, OTTO_DESKTOP_WORKSPACE: workspace },
  stdio: 'inherit',
});

// A page for the Browser checks, served locally so CI needs no internet.
const page = `<!doctype html><title>Otto smoke page</title>
<h1 id="heading">Smoke page</h1>
<button id="press" onclick="this.textContent = 'Pressed'; document.title = 'Pressed'">Press me</button>
<input id="name" aria-label="Your name" oninput="document.getElementById('heading').textContent = this.value">`;
const server = http.createServer((_request, response) => {
  response.writeHead(200, { 'content-type': 'text/html' });
  response.end(page);
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const pageURL = `http://127.0.0.1:${server.address().port}/`;

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
// Every DevTools call has a deadline, so a stuck page fails the run instead of hanging it.
const call = (method, params = {}) =>
  new Promise((resolve, reject) => {
    const id = nextID++;
    const timer = setTimeout(() => {
      waiting.delete(id);
      reject(new Error(`DevTools ${method} timed out`));
    }, 60_000);
    waiting.set(id, (message) => {
      clearTimeout(timer);
      resolve(message);
    });
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

/** Reads the browser tab directly through its own DevTools target (for diagnosing failures). */
async function pageProbe(url) {
  try {
    const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
    const target = targets.find((candidate) => candidate.url.startsWith(url));
    if (!target) return `no target (${targets.map((candidate) => candidate.url).join(', ')})`;
    const tab = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((resolve) => tab.addEventListener('open', resolve));
    const reply = new Promise((resolve) => tab.addEventListener('message', ({ data }) => resolve(JSON.parse(data))));
    tab.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { returnByValue: true, expression: "[document.title, document.getElementById('press')?.textContent, document.visibilityState, document.hasFocus(), innerWidth + 'x' + innerHeight, JSON.stringify(document.getElementById('press')?.getBoundingClientRect())].join(' | ')" } }));
    const value = (await reply).result?.result?.value;
    tab.close();
    return value;
  } catch (error) {
    return `probe failed: ${error.message}`;
  }
}

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
  for (let attempt = 0; attempt < 60 && !ok; attempt += 1) {
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
  for (let attempt = 0; attempt < 120; attempt += 1) {
    if ((await evaluate(engineLine))?.startsWith('Engine ')) break;
    await sleep(500);
  }
  const engine = await evaluate(engineLine);
  console.log(`engine: ${engine}`);
  await shot('1-welcome.png');
  if (!engine?.startsWith('Engine ')) throw new Error(`engine did not start: ${engine}`);
  if (process.env.OTTO_ENGINE_PATH) {
    // With the engine Otto Desktop lands on Home; New chat then offers bots.
    for (let attempt = 0; attempt < 60 && (await evaluate(`document.getElementById('home-surface').hidden`)); attempt += 1) {
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
    for (let attempt = 0; attempt < 60 && !dashboard; attempt += 1) {
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
    for (let attempt = 0; attempt < 60 && !widened; attempt += 1) {
      await sleep(300);
      widened = await evaluate(`Boolean(document.querySelector('.data-card.width-wide'))`);
    }
    await shot('place-dashboards-editing.png');
    if (!widened) throw new Error('making a card wide did not apply');
    await evaluate(`document.getElementById('dashboard-edit').click()`);
    await sleep(300);
    await shot('place-dashboards.png');

    // Browser: open a page from the start screen, then read and act on it through the bot
    // tools (browser.inspect / click / type / screenshot), which run in this app's Chromium.
    await visit('Browser', 'browser', `document.getElementById('browser-tabs') && !document.getElementById('browser').hidden`);
    await evaluate(`(() => {
      document.getElementById('browser-start-input').value = ${JSON.stringify(pageURL)};
      document.getElementById('browser-start-form').requestSubmit();
    })()`);
    let browserState = null;
    for (let attempt = 0; attempt < 120; attempt += 1) {
      await sleep(300);
      browserState = (await evaluate(`window.otto.desktop('browser.list')`))?.[0];
      if (browserState?.state?.title === 'Otto smoke page' && !browserState.state.isLoading) break;
    }
    console.log(`browser: ${browserState?.state?.title} · ${browserState?.state?.url}`);
    if (browserState?.state?.title !== 'Otto smoke page') throw new Error('the browser did not load the page');
    const nodeID = browserState.nodeID;
    const inspected = await evaluate(`window.otto.desktop('browser.inspect', { id: ${JSON.stringify(nodeID)} })`);
    const names = (inspected?.elements ?? []).map((element) => element.name);
    console.log(`bot sees: ${names.join(' | ')}`);
    if (!names.includes('Press me') || !names.includes('Your name')) throw new Error('browser.inspect did not see the page');
    const clickResult = await evaluate(`window.otto.desktop('browser.click', { id: ${JSON.stringify(nodeID)}, element: 'Press me' }).then((value) => JSON.stringify(value), (error) => 'ERROR ' + error.message)`);
    console.log(`click: ${clickResult}`);
    await evaluate(`window.otto.desktop('browser.type', { id: ${JSON.stringify(nodeID)}, element: 'Your name', text: 'Otto on ${process.platform}' })`);
    let after = null;
    for (let attempt = 0; attempt < 60; attempt += 1) {
      await sleep(250);
      after = await evaluate(`window.otto.desktop('browser.inspect', { id: ${JSON.stringify(nodeID)} })`);
      if (after?.elements?.some((element) => element.name === 'Pressed')) break;
    }
    console.log(`after click: ${after?.title}`);
    if (!after?.elements?.some((element) => element.name === 'Pressed')) {
      console.log(`page itself: ${await pageProbe(pageURL)}`);
      throw new Error('browser.click did not press the button');
    }
    const captured = await evaluate(`window.otto.desktop('browser.screenshot', { id: ${JSON.stringify(nodeID)} })`);
    console.log(`screenshot: ${captured?.pixelWidth}×${captured?.pixelHeight}`);
    if (!(captured?.pixelWidth > 0)) throw new Error('browser.screenshot captured nothing');
    await shot('place-browser.png');

    // Teams: hire two bots, create a team through the dialog, land in its room.
    await evaluate(`(async () => {
      await window.otto.engine('bot.create', { name: 'Scout', responsibility: 'Research', provider: 'Claude Code' });
      await window.otto.engine('bot.create', { name: 'Quill', responsibility: 'Write', provider: 'Codex' });
      await refreshRoster();
      renderSidebar();
    })()`);
    if (await evaluate(`document.getElementById('teams-header').hidden`)) throw new Error('the teams group did not appear');
    await evaluate(`document.getElementById('add-team').click()`);
    let members = 0;
    for (let attempt = 0; attempt < 60 && members < 2; attempt += 1) {
      await sleep(250);
      members = await evaluate(`document.getElementById('team-dialog').open ? document.querySelectorAll('.team-member').length : 0`);
    }
    if (members < 2) throw new Error(`the team dialog did not list the bots (${members})`);
    await evaluate(`(() => {
      document.getElementById('team-name').value = 'Smoke crew';
      document.getElementById('team-instructions').value = '@scout researches, @quill writes.';
      document.getElementById('team-instructions').dispatchEvent(new Event('input'));
    })()`);
    await sleep(200);
    await shot('team-dialog.png');
    await evaluate(`document.getElementById('team-save').click()`);
    let room = null;
    for (let attempt = 0; attempt < 90 && room !== 'Smoke crew'; attempt += 1) {
      await sleep(300);
      room = await evaluate(`!document.getElementById('chat').hidden && !document.getElementById('chat-edit-team').hidden ? document.getElementById('chat-name').textContent : null`);
    }
    console.log(`team room: ${room}`);
    if (room !== 'Smoke crew') throw new Error('creating a team did not open its room');
    const teamRow = await evaluate(`document.querySelector('.team-row')?.textContent ?? null`);
    if (!teamRow?.includes('Smoke crew')) throw new Error('the team is not in the rail');
    await shot('team-room.png');

    // Voice: Settings shows it, 24 kHz capture loads, and dictation records and transcribes.
    await evaluate(`document.getElementById('nav-settings').click()`);
    let voiceSettings = null;
    for (let attempt = 0; attempt < 60 && !voiceSettings; attempt += 1) {
      await sleep(300);
      voiceSettings = await evaluate(`document.querySelector('.settings-voice')?.innerText ?? null`);
    }
    console.log(`voice settings: ${voiceSettings?.replace(/\s+/g, ' ').slice(0, 160)}`);
    if (!voiceSettings?.includes('Provider')) throw new Error('Settings has no Voice section');
    if (process.env.CI) {
      // On CI only: saving writes to the real OS keychain.
      await evaluate(`(() => {
        const field = document.querySelector('.settings-key input');
        field.value = 'sk-smoke-not-real';
        document.querySelector('.settings-key .primary').click();
      })()`);
      let saved = null;
      for (let attempt = 0; attempt < 60 && !saved; attempt += 1) {
        await sleep(300);
        saved = await evaluate(`document.querySelector('.settings-key')?.textContent.includes('key saved') || null`);
      }
      if (!saved) throw new Error('saving a voice key did not stick');
      const kept = await evaluate(`window.otto.desktop('voice.status').then((status) => status.keys.openai)`);
      console.log(`voice key kept in keychain: ${kept}`);
      if (!kept) throw new Error('the engine does not see the saved key');
    }
    await shot('settings-voice.png');
    const capture = await evaluate(`(async () => {
      const context = new AudioContext({ sampleRate: 24000 });
      await context.audioWorklet.addModule('audio-capture.js');
      const rate = context.sampleRate;
      await context.close();
      return rate;
    })().catch((error) => 'failed: ' + error.message)`);
    console.log(`voice capture: ${capture}`);
    if (capture !== 24000) throw new Error(`voice audio capture did not load (${capture})`);
    await evaluate(`go('welcome')`);
    await sleep(400);
    await evaluate(`document.getElementById('welcome-mic').click()`);
    let recording = false;
    for (let attempt = 0; attempt < 90 && !recording; attempt += 1) {
      await sleep(250);
      recording = await evaluate(`document.getElementById('welcome-mic').classList.contains('recording')`);
    }
    await sleep(800); // record a little audio
    if (!recording) {
      console.log(`dictation probe: ${await evaluate(`JSON.stringify({ welcomeHidden: document.getElementById('welcome').hidden, toast: document.getElementById('toast').hidden ? null : document.getElementById('toast').textContent, devices: typeof navigator.mediaDevices?.getUserMedia })`)}`);
      console.log(`media probe: ${await evaluate(`navigator.mediaDevices.getUserMedia({ audio: true }).then((stream) => 'ok ' + stream.getAudioTracks().length, (error) => 'failed ' + error.name + ' ' + error.message)`)}`);
    }
    await evaluate(`document.getElementById('welcome-mic').click()`);
    let dictation = null;
    for (let attempt = 0; attempt < 120 && !dictation; attempt += 1) {
      await sleep(300);
      dictation = await evaluate(`document.getElementById('toast').hidden ? null : document.getElementById('toast').textContent`);
    }
    console.log(`dictation: recording=${recording} · ${dictation}`);
    // With no real key the transcription is refused, which proves the clip reached the service.
    if (!recording || !/API key|Incorrect API key|invalid|401/i.test(dictation ?? '')) {
      throw new Error(`dictation did not record and transcribe (${dictation})`);
    }
    await evaluate(`document.getElementById('toast').hidden = true`);

    await visit('Automations', 'automations', `document.querySelector('#automations-body .overline')`);
    await evaluate(`(() => {
      document.getElementById('new-automation').click();
      document.getElementById('automation-name').value = 'Smoke digest';
      document.getElementById('automation-instruction').value = 'Say hello';
      document.querySelector('#automation-form button[value=create]').click();
    })()`);
    let automation = null;
    for (let attempt = 0; attempt < 60 && !automation; attempt += 1) {
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
    for (let attempt = 0; attempt < 60 && !heading; attempt += 1) {
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
  for (let attempt = 0; attempt < 120 && !text.includes(`${marker} on`); attempt += 1) {
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
  server.close();
  // Wait for the app to exit, so a following run can take the debugging port.
  const exited = new Promise((resolve) => app.once('exit', resolve));
  app.kill();
  await Promise.race([exited, sleep(10_000)]);
}
if (failure) {
  console.error(failure.message);
  process.exit(1);
}
console.log('desktop smoke test passed');
process.exit(0);
