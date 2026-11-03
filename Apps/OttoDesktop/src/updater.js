// Updates for installed Otto Desktop builds, like the Mac app's: check the feed on launch and
// every few hours, offer "Download & Restart", and install only what the release key signed.
// electron-updater does the platform work (silent NSIS install on Windows, AppImage swap and deb
// install on Linux); update-manifest.js decides whether the downloaded file may run.
'use strict';

const fs = require('node:fs');
const { app } = require('electron');
const { verifyDownload } = require('./update-manifest');

const FEED = 'https://maxtrigify.github.io/muse-releases/desktop';
const CHECK_EVERY_MS = 6 * 60 * 60 * 1000;

class Updater {
  constructor({ notify }) {
    this.notify = notify;
    this.state = { phase: 'idle', version: app.getVersion() };
    this.updater = null;
  }

  set(next) {
    this.state = { ...this.state, ...next };
    this.notify('update:state', this.state);
  }

  /** Development runs and unpackaged builds have nothing to update. */
  get supported() {
    if (!app.isPackaged) return false;
    if (process.platform === 'linux' && !process.env.APPIMAGE && !fs.existsSync('/usr/bin/dpkg')) return false;
    return process.platform === 'win32' || process.platform === 'linux';
  }

  start() {
    if (!this.supported) {
      this.set({ phase: 'unsupported' });
      return;
    }
    const { autoUpdater } = require('electron-updater');
    this.updater = autoUpdater;
    autoUpdater.autoDownload = false;
    autoUpdater.autoInstallOnAppQuit = false;
    autoUpdater.setFeedURL({ provider: 'generic', url: FEED });
    autoUpdater.on('checking-for-update', () => this.set({ phase: 'checking', error: null }));
    autoUpdater.on('update-not-available', () => this.set({ phase: 'current', checkedAt: Date.now() }));
    autoUpdater.on('update-available', (info) =>
      this.set({ phase: 'available', available: info.version, notes: notesText(info.releaseNotes), checkedAt: Date.now() }),
    );
    autoUpdater.on('download-progress', (progress) => this.set({ phase: 'downloading', percent: Math.round(progress.percent) }));
    autoUpdater.on('update-downloaded', (event) => this.verify(event));
    autoUpdater.on('error', (error) => this.set({ phase: 'error', error: error.message }));
    this.check();
    this.timer = setInterval(() => this.check(), CHECK_EVERY_MS);
  }

  check() {
    if (!this.updater || ['downloading', 'verifying', 'ready'].includes(this.state.phase)) return;
    this.updater.checkForUpdates().catch((error) => this.set({ phase: 'error', error: error.message }));
  }

  download() {
    if (this.state.phase !== 'available') return;
    this.set({ phase: 'downloading', percent: 0 });
    this.updater.downloadUpdate().catch((error) => this.set({ phase: 'error', error: error.message }));
  }

  /** The installer runs only if it matches the release key's signed manifest. */
  async verify(event) {
    this.set({ phase: 'verifying' });
    try {
      const response = await fetch(`${FEED}/manifest.json`, { cache: 'no-store' });
      if (!response.ok) throw new Error(`The signed manifest is unavailable (${response.status})`);
      await verifyDownload({ document: await response.json(), version: event.version, file: event.downloadedFile });
      this.set({ phase: 'ready', available: event.version });
    } catch (error) {
      fs.rmSync(event.downloadedFile, { force: true });
      this.set({ phase: 'error', error: `Update refused: ${error.message}` });
    }
  }

  install() {
    if (this.state.phase !== 'ready') return;
    // Silent on Windows (no installer pages), then relaunch Otto.
    this.updater.quitAndInstall(true, true);
  }

  dispose() {
    clearInterval(this.timer);
  }
}

function notesText(notes) {
  if (!notes) return '';
  if (typeof notes === 'string') return notes.replace(/<[^>]+>/g, '').trim();
  return notes.map((entry) => `${entry.version}: ${String(entry.note ?? '').replace(/<[^>]+>/g, '')}`).join('\n');
}

module.exports = { Updater, FEED };
