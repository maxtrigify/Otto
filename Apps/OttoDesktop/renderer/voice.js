'use strict';

// Talk to Otto and dictation. The engine runs the Mac's voice session; this page is its
// microphone and speakers (24 kHz mono PCM16 through Chromium's audio stack) and shows what it
// heard and said. Dictation records a clip and has the main process transcribe it.
const Voice = (() => {
  const $ = (id) => document.getElementById(id);
  const RATE = 24_000;
  const LABELS = {
    disconnected: 'Off',
    connecting: 'Connecting…',
    sleeping: 'Paused',
    listening: 'Listening',
    userSpeaking: 'Hearing you',
    endOfTurn: 'Thinking…',
    thinking: 'Thinking…',
    callingTool: 'Working…',
    speaking: 'Speaking',
    interrupted: 'Listening',
    error: 'Voice error',
  };
  const LIVE = new Set(['connecting', 'listening', 'userSpeaking', 'endOfTurn', 'thinking', 'callingTool', 'speaking', 'interrupted']);
  let status = null;
  let hooks = { onError: () => {}, toast: () => {} };

  // ---- Audio --------------------------------------------------------------------------------

  let context = null;
  let stream = null;
  let capture = null;
  let inputEnabled = true;
  let playhead = 0;
  let playing = new Set();
  let loudFrames = 0;
  let lastSpeech = 0;

  async function audioContext() {
    if (!context || context.state === 'closed') {
      context = new AudioContext({ sampleRate: RATE, latencyHint: 'interactive' });
      await context.audioWorklet.addModule('audio-capture.js');
    }
    if (context.state === 'suspended') await context.resume();
    return context;
  }

  const toBase64 = (bytes) => {
    let binary = '';
    for (let index = 0; index < bytes.length; index += 0x8000) binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
    return btoa(binary);
  };

  async function startMicrophone() {
    const ctx = await audioContext();
    stream = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
    const source = ctx.createMediaStreamSource(stream);
    capture = new AudioWorkletNode(ctx, 'pcm-capture');
    capture.port.onmessage = ({ data }) => {
      if (!inputEnabled) return;
      const pcm = new Int16Array(data.samples.length);
      for (let index = 0; index < pcm.length; index += 1) {
        const sample = Math.max(-1, Math.min(1, data.samples[index]));
        pcm[index] = sample < 0 ? sample * 0x8000 : sample * 0x7fff;
      }
      window.otto.voiceMic(toBase64(new Uint8Array(pcm.buffer)));
      // Speaking over Otto interrupts it, as on the Mac.
      loudFrames = data.rms > 0.04 ? loudFrames + 1 : 0;
      if (loudFrames >= 3 && playing.size && Date.now() - lastSpeech > 1000) {
        lastSpeech = Date.now();
        window.otto.voiceSpeech();
      }
      $('voice-level').style.setProperty('--level', Math.min(1, data.rms * 12).toFixed(2));
    };
    source.connect(capture);
    // The worklet must be pulled by the graph; route it to a silent sink.
    const sink = ctx.createGain();
    sink.gain.value = 0;
    capture.connect(sink).connect(ctx.destination);
  }

  function stopMicrophone() {
    capture?.disconnect();
    capture = null;
    for (const track of stream?.getTracks() ?? []) track.stop();
    stream = null;
  }

  async function play(base64) {
    const ctx = await audioContext();
    const bytes = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
    const pcm = new Int16Array(bytes.buffer, 0, Math.floor(bytes.length / 2));
    if (!pcm.length) return;
    const buffer = ctx.createBuffer(1, pcm.length, RATE);
    const channel = buffer.getChannelData(0);
    for (let index = 0; index < pcm.length; index += 1) channel[index] = pcm[index] / 0x8000;
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.connect(ctx.destination);
    playhead = Math.max(playhead, ctx.currentTime + 0.02);
    source.start(playhead);
    playhead += buffer.duration;
    playing.add(source);
    source.onended = () => playing.delete(source);
  }

  function flush() {
    for (const source of playing) {
      try {
        source.stop();
      } catch {}
    }
    playing.clear();
    playhead = 0;
  }

  async function drained() {
    while (playing.size) await new Promise((resolve) => setTimeout(resolve, 50));
  }

  /** Requests from the engine (through the main process) for the microphone and speakers. */
  async function onAudio(message) {
    const answer = (ok, error) => message.id && window.otto.voiceAnswer({ id: message.id, ok, error });
    try {
      switch (message.op) {
        case 'start':
          if (!stream) await startMicrophone();
          return answer(true);
        case 'stop':
          stopMicrophone();
          flush();
          return answer(true);
        case 'drain':
          await drained();
          return answer(true);
        case 'play':
          return play(message.pcm);
        case 'flush':
          return flush();
        case 'inputEnabled':
          inputEnabled = Boolean(message.enabled);
          return;
        default:
          return;
      }
    } catch (error) {
      answer(false, error.name === 'NotAllowedError' ? 'Otto is not allowed to use the microphone' : error.message);
    }
  }

  // ---- Talk ---------------------------------------------------------------------------------

  const isLive = () => LIVE.has(status?.state);

  async function call(method, params) {
    try {
      status = await window.otto.desktop(method, params);
      render();
      return status;
    } catch (error) {
      hooks.onError(error);
      return null;
    }
  }

  async function toggleTalk() {
    if (!status) await refresh();
    if (isLive()) return call('voice.sleep');
    if (!status?.keys?.[status.provider]) {
      hooks.toast(`Add your ${status?.provider === 'xai' ? 'xAI' : 'OpenAI'} API key in Settings → Voice to talk to Otto.`);
      hooks.openSettings?.();
      return;
    }
    $('voice-panel').hidden = false;
    return call('voice.talk');
  }

  function render() {
    if (!status) return;
    const live = isLive();
    const button = $('voice-button');
    button.classList.toggle('live', live);
    button.classList.toggle('error', status.state === 'error');
    button.title = live ? 'Stop talking' : 'Talk to Otto';
    $('voice-button-label').textContent = live ? LABELS[status.state] : 'Talk';
    $('voice-panel').classList.toggle('live', live);
    $('voice-state').textContent = status.lastError && status.state === 'error' ? status.lastError : LABELS[status.state] ?? status.state;
    $('voice-partial').textContent = status.partialTranscript || '';
    const list = $('voice-conversation');
    list.replaceChildren();
    for (const record of status.conversation.slice(-8)) {
      const line = document.createElement('div');
      line.className = `voice-line ${record.role}`;
      line.textContent = record.text;
      list.append(line);
    }
    list.scrollTop = list.scrollHeight;
    $('voice-stop').textContent = live ? 'Stop' : 'Talk';
    $('voice-interrupt').hidden = status.state !== 'speaking';
  }

  async function refresh() {
    try {
      status = await window.otto.desktop('voice.status');
      render();
    } catch {
      status = null;
    }
    return status;
  }

  // ---- Dictation ----------------------------------------------------------------------------

  let recorder = null;

  /** Toggles dictation into `input`; the button shows recording while it listens. */
  async function dictate(input, button) {
    if (recorder) {
      recorder.stop();
      return;
    }
    let microphone;
    try {
      microphone = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true } });
    } catch {
      hooks.toast('Otto is not allowed to use the microphone');
      return;
    }
    const mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus') ? 'audio/webm;codecs=opus' : '';
    const chunks = [];
    recorder = new MediaRecorder(microphone, mimeType ? { mimeType } : undefined);
    recorder.ondataavailable = (event) => event.data.size && chunks.push(event.data);
    recorder.onstop = async () => {
      for (const track of microphone.getTracks()) track.stop();
      recorder = null;
      button.classList.remove('recording');
      button.classList.add('busy');
      try {
        const blob = new Blob(chunks, { type: chunks[0]?.type || 'audio/webm' });
        const audio = toBase64(new Uint8Array(await blob.arrayBuffer()));
        const text = await window.otto.transcribe(audio, blob.type);
        if (text) {
          const start = input.selectionStart ?? input.value.length;
          const before = input.value.slice(0, start);
          const spacer = before && !/\s$/.test(before) ? ' ' : '';
          input.value = before + spacer + text + input.value.slice(input.selectionEnd ?? start);
          input.dispatchEvent(new Event('input'));
          input.focus();
        }
      } catch (error) {
        hooks.onError(error);
      } finally {
        button.classList.remove('busy');
      }
    };
    recorder.start();
    button.classList.add('recording');
  }

  // ---- Settings -----------------------------------------------------------------------------

  /** The Voice section of Settings: provider, voice and API keys kept in the OS keychain. */
  async function settingsSection() {
    await refresh();
    const keychain = await window.otto.keychain();
    const section = document.createElement('section');
    section.className = 'settings-voice';
    const heading = document.createElement('div');
    heading.className = 'overline';
    heading.textContent = 'Voice';
    section.append(heading);
    if (!status) {
      const note = document.createElement('p');
      note.className = 'muted small';
      note.textContent = 'Voice starts with the chat engine.';
      section.append(note);
      return section;
    }
    const row = (label, control) => {
      const line = document.createElement('label');
      line.className = 'settings-row';
      const text = document.createElement('span');
      text.textContent = label;
      line.append(text, control);
      return line;
    };
    const provider = document.createElement('select');
    for (const [value, name] of [['openai', 'OpenAI'], ['xai', 'xAI (Grok)']]) {
      const option = new Option(name, value, false, status.provider === value);
      provider.append(option);
    }
    const voice = document.createElement('select');
    const fillVoices = () => {
      voice.replaceChildren();
      for (const option of status.voices[provider.value] ?? []) {
        voice.append(new Option(`${option.name}${option.recommended ? ' · recommended' : ''}`, option.id, false, option.id === status.voice));
      }
    };
    fillVoices();
    provider.addEventListener('change', async () => {
      await call('voice.configure', { provider: provider.value });
      fillVoices();
      renderKey();
    });
    voice.addEventListener('change', () => call('voice.configure', { provider: provider.value, voice: voice.value }));
    section.append(row('Provider', provider), row('Voice', voice));

    const keyLine = document.createElement('div');
    keyLine.className = 'settings-key';
    const renderKey = () => {
      keyLine.replaceChildren();
      const name = provider.value === 'xai' ? 'xAI' : 'OpenAI';
      if (status.keys[provider.value]) {
        const saved = document.createElement('span');
        saved.textContent = `${name} key saved`;
        const remove = document.createElement('button');
        remove.className = 'ghost small-button';
        remove.textContent = 'Remove';
        remove.addEventListener('click', async () => {
          await call('voice.setKey', { provider: provider.value, key: null });
          renderKey();
        });
        keyLine.append(saved, remove);
      } else {
        const field = document.createElement('input');
        field.type = 'password';
        field.autocomplete = 'off';
        field.placeholder = `${name} API key`;
        field.setAttribute('aria-label', `${name} API key`);
        const save = document.createElement('button');
        save.className = 'primary small-button';
        save.textContent = 'Save key';
        save.addEventListener('click', async () => {
          if (!field.value.trim()) return;
          await call('voice.setKey', { provider: provider.value, key: field.value });
          field.value = '';
          renderKey();
        });
        keyLine.append(field, save);
      }
    };
    renderKey();
    section.append(keyLine);
    const where = document.createElement('p');
    where.className = 'muted small';
    where.textContent = keychain.protected
      ? `Keys are encrypted with ${keychain.backend} and never shown again. Dictation uses the OpenAI key.`
      : 'No system keychain was found, so keys are stored without OS encryption. Install GNOME Keyring or KWallet to protect them.';
    section.append(where);
    return section;
  }

  function wire() {
    window.otto.onVoiceAudio((message) => onAudio(message));
    window.otto.onVoiceState((next) => {
      status = next;
      render();
    });
    $('voice-button').addEventListener('click', toggleTalk);
    $('voice-stop').addEventListener('click', toggleTalk);
    $('voice-interrupt').addEventListener('click', () => call('voice.interrupt'));
    $('voice-close').addEventListener('click', async () => {
      if (isLive()) await call('voice.sleep');
      $('voice-panel').hidden = true;
    });
  }

  return {
    wire,
    refresh,
    dictate,
    settingsSection,
    toggleTalk,
    configure(next) {
      hooks = { ...hooks, ...next };
    },
    get status() {
      return status;
    },
  };
})();
