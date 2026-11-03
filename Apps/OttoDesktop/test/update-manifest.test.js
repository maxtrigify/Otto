// The update gate: only an installer whose hash the release key signed may run.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { verifyManifest, verifyDownload, sha512, TRUSTED_KEYS } = require('../src/update-manifest');

// A throwaway key pair stands in for the release key.
const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
const rawPublic = publicKey.export({ format: 'der', type: 'spki' }).subarray(12).toString('base64');
const keys = { 'test-key': rawPublic };

/** A SignedDocument exactly as otto-release writes it: base64 payload and signature. */
function sign(manifest, key = privateKey, keyID = 'test-key') {
  const payload = Buffer.from(JSON.stringify(manifest));
  return { payload: payload.toString('base64'), signature: crypto.sign(null, payload, key).toString('base64'), keyID };
}

function installer(t, contents) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'otto-update-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const file = path.join(directory, 'Otto-Setup-0.2.0-x64.exe');
  fs.writeFileSync(file, contents);
  return file;
}

const manifestFor = async (file, overrides = {}) => ({
  product: 'otto-desktop',
  version: '0.2.0',
  releasedAt: '2026-11-03T12:00:00Z',
  files: [{ platform: 'win32', arch: 'x64', kind: 'nsis', name: path.basename(file), url: 'https://github.com/x/y/releases/download/desktop-v0.2.0/a.exe', sha512: await sha512(file), size: 4 }],
  ...overrides,
});

test('the real release key is trusted', () => {
  assert.equal(Buffer.from(TRUSTED_KEYS['muse-2026-1'], 'base64').length, 32);
});

test('a signed installer verifies', async (t) => {
  const file = installer(t, 'good');
  const document = sign(await manifestFor(file));
  const entry = await verifyDownload({ document, version: '0.2.0', file, platform: 'win32', arch: 'x64', keys });
  assert.equal(entry.kind, 'nsis');
});

test('a changed installer is refused', async (t) => {
  const file = installer(t, 'good');
  const document = sign(await manifestFor(file));
  fs.writeFileSync(file, 'evil');
  await assert.rejects(verifyDownload({ document, version: '0.2.0', file, platform: 'win32', arch: 'x64', keys }), /does not match/);
});

test('a manifest signed by another key, or edited after signing, is refused', async (t) => {
  const file = installer(t, 'good');
  const manifest = await manifestFor(file);
  const stranger = crypto.generateKeyPairSync('ed25519').privateKey;
  assert.throws(() => verifyManifest(sign(manifest, stranger), keys), /signature is not valid/);
  const edited = sign(manifest);
  edited.payload = Buffer.from(JSON.stringify({ ...manifest, version: '9.9.9' })).toString('base64');
  assert.throws(() => verifyManifest(edited, keys), /signature is not valid/);
  assert.throws(() => verifyManifest(sign(manifest, privateKey, 'unknown'), keys), /unknown key/);
});

test('a Mac manifest or another version cannot pass as this update', async (t) => {
  const file = installer(t, 'good');
  const mac = sign(await manifestFor(file, { product: 'otto-mac' }));
  assert.throws(() => verifyManifest(mac, keys), /not for Otto Desktop/);
  await assert.rejects(
    verifyDownload({ document: sign(await manifestFor(file)), version: '0.3.0', file, platform: 'win32', arch: 'x64', keys }),
    /not 0.3.0/,
  );
  await assert.rejects(
    verifyDownload({ document: sign(await manifestFor(file)), version: '0.2.0', file, platform: 'linux', arch: 'x64', keys }),
    /does not match/,
  );
});
