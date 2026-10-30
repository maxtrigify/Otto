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

const app = spawn(electron, ['.', `--remote-debugging-port=${port}`], {
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
socket.addEventListener('message', ({ data }) => {
  const message = JSON.parse(data);
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
try {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    if ((await evaluate(`document.getElementById('engine-status').textContent`))?.startsWith('Engine ')) break;
    await sleep(500);
  }
  const engine = await evaluate(`document.getElementById('engine-status').textContent`);
  console.log(`engine: ${engine}`);
  await shot('1-welcome.png');
  if (!engine?.startsWith('Engine ')) throw new Error(`engine did not start: ${engine}`);

  await evaluate(`[...document.querySelectorAll('.agent-card')].find((b) => b.textContent.startsWith('Terminal')).click()`);
  await sleep(4000);
  await evaluate(`document.querySelector('.terminal-host:not([hidden]) textarea').focus()`);
  const marker = 'otto-smoke-ok';
  await type(process.platform === 'win32' ? `Write-Output "${marker} on $([Environment]::OSVersion.VersionString)"` : `echo "${marker} on $(uname -s)"`);
  let text = '';
  for (let attempt = 0; attempt < 40 && !text.includes(`${marker} on`); attempt += 1) {
    await sleep(500);
    text = await evaluate(
      `[...document.querySelectorAll('.terminal-host:not([hidden]) .xterm-rows > div')].map((row) => row.textContent).join('\\n')`,
    );
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
