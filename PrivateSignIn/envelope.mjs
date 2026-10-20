import { CipherSuite, DhkemP256HkdfSha256, HkdfSha256, Aes256Gcm } from '@hpke/core';

const suite = new CipherSuite({kem: new DhkemP256HkdfSha256(), kdf: new HkdfSha256(), aead: new Aes256Gcm()});
const encoder = new TextEncoder();
// Legacy wire name, do not change without a protocol version bump.
const info = encoder.encode('muse-private-input-hpke-auth-v1');
export const maximumPlaintextBytes = 65536;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// The 'muse-private-input-v1' label below is a legacy wire name, do not change without a
// protocol version bump.
function contextBytes(c) {
  if (!c || ![c.installationID,c.sessionID,c.operationID].every(v => typeof v === 'string' && uuid.test(v)) ||
      !['phoneToHost','hostToPhone'].includes(c.direction) || !Number.isSafeInteger(c.expiresAt) || c.expiresAt <= 0) throw new Error('Invalid private input');
  return encoder.encode(['muse-private-input-v1',c.installationID.toLowerCase(),c.sessionID.toLowerCase(),
    c.operationID.toLowerCase(),c.direction,String(c.expiresAt)].join('\n'));
}
function base64(bytes) {
  const input = new Uint8Array(bytes); let text = '';
  for (let i=0;i<input.length;i+=8192) text += String.fromCharCode(...input.subarray(i,i+8192));
  return btoa(text);
}
function bytes(value, max) {
  if (typeof value !== 'string' || value.length > Math.ceil(max/3)*4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) throw new Error('Invalid private input');
  const result = Uint8Array.from(atob(value), c => c.charCodeAt(0));
  if (result.length > max) throw new Error('Invalid private input');
  return result;
}
export async function generateKeyPair() { return suite.kem.generateKeyPair(); }
export async function exportPublicKey(key) { return base64(await suite.kem.serializePublicKey(key)); }
export async function importPublicKey(value) { return suite.kem.deserializePublicKey(bytes(value,65)); }
export async function seal(plaintext, context, recipientPublicKey, senderKey) {
  if (!(plaintext instanceof Uint8Array) || plaintext.length > maximumPlaintextBytes) throw new Error('Invalid private input');
  const aad = contextBytes(context);
  const sender = await suite.createSenderContext({recipientPublicKey,senderKey,info});
  const ciphertext = await sender.seal(plaintext,aad);
  return {version:1,context:{...context},encapsulatedKey:base64(sender.enc),ciphertext:base64(ciphertext)};
}
export async function open(envelope, expected, recipientKey, senderPublicKey, now = Date.now()) {
  try {
    const aad = contextBytes(expected);
    const received = contextBytes(envelope.context);
    if (envelope.version !== 1 || expected.expiresAt*1000 <= now || aad.length !== received.length ||
      !aad.every((v,i) => v === received[i])) throw new Error();
    const enc = bytes(envelope.encapsulatedKey,65);
    const ct = bytes(envelope.ciphertext,maximumPlaintextBytes+16);
    if (enc.length !== 65 || ct.length < 16) throw new Error();
    const recipient = await suite.createRecipientContext({recipientKey,senderPublicKey,enc,info});
    return new Uint8Array(await recipient.open(ct,aad));
  } catch { throw new Error('Invalid private input'); }
}
