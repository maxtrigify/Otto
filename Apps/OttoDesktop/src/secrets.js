// Secrets for the engine (voice and app API keys), encrypted with the operating system's
// keychain through Electron safeStorage: DPAPI on Windows, the Secret Service (GNOME Keyring,
// KWallet) on Linux, the Keychain on macOS. Only ciphertext touches disk.
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { safeStorage } = require('electron');

class SecretVault {
  constructor(file) {
    this.file = file;
  }

  /** Where the encryption key lives, for Settings ("Windows Credential Manager" etc.). */
  describe() {
    if (!safeStorage.isEncryptionAvailable()) return { protected: false, backend: 'none' };
    if (process.platform === 'win32') return { protected: true, backend: 'Windows (DPAPI)' };
    if (process.platform === 'darwin') return { protected: true, backend: 'macOS Keychain' };
    const backend = safeStorage.getSelectedStorageBackend?.() ?? 'unknown';
    // basic_text means no keyring was found; the key is then only obfuscated.
    return { protected: backend !== 'basic_text' && backend !== 'unknown', backend };
  }

  load() {
    try {
      return JSON.parse(fs.readFileSync(this.file, 'utf8'));
    } catch {
      return {};
    }
  }

  save(entries) {
    fs.mkdirSync(path.dirname(this.file), { recursive: true, mode: 0o700 });
    const temporary = `${this.file}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify(entries), { mode: 0o600 });
    fs.renameSync(temporary, this.file);
  }

  get(key) {
    const entry = this.load()[key];
    if (!entry) return null;
    if (entry.encrypted) {
      if (!safeStorage.isEncryptionAvailable()) throw new Error('The system keychain is locked or unavailable');
      return safeStorage.decryptString(Buffer.from(entry.value, 'base64'));
    }
    return entry.value;
  }

  set(key, value) {
    const entries = this.load();
    entries[key] = safeStorage.isEncryptionAvailable()
      ? { encrypted: true, value: safeStorage.encryptString(value).toString('base64') }
      : { encrypted: false, value };
    this.save(entries);
    return true;
  }

  delete(key) {
    const entries = this.load();
    if (key in entries) {
      delete entries[key];
      this.save(entries);
    }
    return true;
  }
}

module.exports = { SecretVault };
