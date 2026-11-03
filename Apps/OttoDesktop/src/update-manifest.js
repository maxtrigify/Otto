// Verifies Otto Desktop updates the way the Mac app verifies its own: the release feed carries an
// Ed25519-signed manifest (otto-release sign-desktop-manifest, key muse-2026-1), and a downloaded
// installer is only run if its SHA-512 matches the signed entry. A tampered website or GitHub
// release cannot push a build without the release key.
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');

/** Trusted release keys (raw Ed25519 public keys), as in AppUpdateController.swift. */
const TRUSTED_KEYS = {
  'muse-2026-1': 'yf0EYlEAlBCEF5spXmxgAraJ1RqgQdfBk7HipdGu4o0=',
};

function publicKey(raw) {
  // SubjectPublicKeyInfo for Ed25519: fixed 12-byte prefix + the 32-byte key.
  const der = Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(raw, 'base64')]);
  return crypto.createPublicKey({ key: der, format: 'der', type: 'spki' });
}

/** Returns the manifest inside a SignedDocument, or throws if the signature does not hold. */
function verifyManifest(document, keys = TRUSTED_KEYS) {
  const raw = keys[document?.keyID];
  if (!raw) throw new Error(`Update signed with an unknown key (${document?.keyID})`);
  const payload = Buffer.from(document.payload, 'base64');
  const signature = Buffer.from(document.signature, 'base64');
  if (!crypto.verify(null, payload, publicKey(raw), signature)) throw new Error('The update signature is not valid');
  const manifest = JSON.parse(payload.toString('utf8'));
  if (manifest.product !== 'otto-desktop') throw new Error('The update is not for Otto Desktop');
  return manifest;
}

function sha512(file) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha512');
    fs.createReadStream(file)
      .on('data', (chunk) => hash.update(chunk))
      .on('error', reject)
      .on('end', () => resolve(hash.digest('base64')));
  });
}

/** Checks a downloaded installer against the signed manifest for `version`. */
async function verifyDownload({ document, version, file, platform = process.platform, arch = process.arch, keys }) {
  const manifest = verifyManifest(document, keys);
  if (manifest.version !== version) throw new Error(`The signed manifest is for ${manifest.version}, not ${version}`);
  const digest = await sha512(file);
  const entry = manifest.files.find((candidate) => candidate.platform === platform && candidate.arch === arch && candidate.sha512 === digest);
  if (!entry) throw new Error('The downloaded update does not match the signed release');
  return entry;
}

module.exports = { verifyManifest, verifyDownload, sha512, TRUSTED_KEYS };
