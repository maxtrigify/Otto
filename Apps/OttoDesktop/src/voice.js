// Otto Desktop's side of voice. The engine runs the Mac's voice session; this process opens its
// WebSocket to the voice provider and relays microphone and speaker audio between the engine
// and the window (which captures and plays 24 kHz PCM with Chromium's audio stack).
'use strict';

const crypto = require('node:crypto');
const WebSocket = require('ws');

const TRANSCRIBE_URL = 'https://api.openai.com/v1/audio/transcriptions';
const TRANSCRIBE_MODEL = 'gpt-4o-mini-transcribe';

class VoiceHost {
  /** `engine()` is the running EngineClient, `send(channel, payload)` reaches the window. */
  constructor({ engine, send, vault }) {
    this.engine = engine;
    this.send = send;
    this.vault = vault;
    this.sockets = new Map();
    this.waiting = new Map(); // audio requests to the window awaiting its answer
  }

  // ---- Host calls and events from the engine ------------------------------------------------

  handles(method) {
    return method.startsWith('socket.') || method.startsWith('audio.') || method.startsWith('secrets.');
  }

  async handle(method, params) {
    switch (method) {
      case 'secrets.get':
        return this.vault.get(params.key);
      case 'secrets.set':
        return this.vault.set(params.key, params.value);
      case 'secrets.delete':
        return this.vault.delete(params.key);
      case 'socket.open':
        return this.open(params);
      case 'audio.start':
      case 'audio.drain':
      case 'audio.stop':
        return this.askWindow(method.slice('audio.'.length));
      default:
        throw new Error(`Unknown host call ${method}`);
    }
  }

  /** Fire-and-forget lines from the engine. */
  event(kind, payload) {
    switch (kind) {
      case 'socket.send':
        this.sockets.get(payload.id)?.send(payload.text);
        break;
      case 'socket.close':
        this.sockets.get(payload.id)?.close(1000);
        this.sockets.delete(payload.id);
        break;
      case 'audio.play':
      case 'audio.flush':
      case 'audio.inputEnabled':
        this.send('voice:audio', { op: kind.slice('audio.'.length), ...payload });
        break;
      case 'voice.state':
        this.send('voice:state', payload);
        break;
      default:
        break;
    }
  }

  open({ id, url, headers }) {
    if (!/^wss:\/\/api\.(openai\.com|x\.ai)\//.test(url)) throw new Error('Voice can only connect to OpenAI or xAI');
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(url, { headers });
      let opened = false;
      socket.on('open', () => {
        opened = true;
        this.sockets.set(id, socket);
        resolve(true);
      });
      socket.on('message', (data) => this.engine()?.event(`socket.message.${id}`, { id, text: data.toString() }));
      socket.on('close', () => {
        this.sockets.delete(id);
        this.engine()?.event(`socket.closed.${id}`, { id });
      });
      socket.on('error', (error) => {
        if (!opened) reject(new Error(`The voice service refused the connection: ${error.message}`));
      });
    });
  }

  // ---- The window's microphone and speakers ------------------------------------------------

  askWindow(op) {
    const id = crypto.randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiting.delete(id);
        op === 'start' ? reject(new Error('The microphone did not start')) : resolve(true);
      }, op === 'start' ? 15_000 : 10_000);
      this.waiting.set(id, { resolve, reject, timer });
      this.send('voice:audio', { op, id });
    });
  }

  /** The window answered an audio request (start, drain, stop). */
  answer({ id, ok, error }) {
    const waiter = this.waiting.get(id);
    if (!waiter) return;
    this.waiting.delete(id);
    clearTimeout(waiter.timer);
    if (ok) waiter.resolve(true);
    else waiter.reject(new Error(error || 'Audio failed'));
  }

  microphone(pcm) {
    this.engine()?.event('audio.input', { pcm });
  }

  speechStarted() {
    this.engine()?.event('audio.speech', {});
  }

  // ---- Dictation ---------------------------------------------------------------------------

  /** Speech to text with OpenAI, using the key from the keychain; the window never sees it. */
  async transcribe({ audio, mimeType }) {
    const key = this.vault.get('openai.api-key');
    if (!key) throw new Error('Add an OpenAI API key in Settings → Voice to dictate');
    const extension = /ogg/.test(mimeType) ? 'ogg' : /mp4|m4a/.test(mimeType) ? 'm4a' : 'webm';
    const form = new FormData();
    form.append('model', TRANSCRIBE_MODEL);
    form.append('file', new Blob([Buffer.from(audio, 'base64')], { type: mimeType }), `dictation.${extension}`);
    const response = await fetch(TRANSCRIBE_URL, { method: 'POST', headers: { authorization: `Bearer ${key}` }, body: form });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(body.error?.message || `Transcription failed (${response.status})`);
    return String(body.text ?? '').trim();
  }

  dispose() {
    for (const socket of this.sockets.values()) socket.close(1000);
    this.sockets.clear();
  }
}

module.exports = { VoiceHost };
