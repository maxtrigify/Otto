import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID, randomBytes} from 'node:crypto';
import {generateKeyPair,seal,open,maximumPlaintextBytes} from '../envelope.mjs';

const context = () => ({installationID:randomUUID(),sessionID:randomUUID(),operationID:randomUUID(),direction:'phoneToHost',expiresAt:Math.floor(Date.now()/1000)+300});
test('authenticated round trip and independent concurrent envelopes',async () => {
  const host=await generateKeyPair(), phone=await generateKeyPair(), c=context();
  const input=new Uint8Array(randomBytes(32));
  const envelopes=await Promise.all(Array.from({length:8},()=>seal(input,c,host.publicKey,phone.privateKey)));
  assert.equal(new Set(envelopes.map(e=>e.encapsulatedKey)).size,8);
  for (const e of envelopes) assert.deepEqual(await open(e,c,host.privateKey,phone.publicKey),input);
});
test('wrong recipient, sender, context, tampering and expiry fail closed',async () => {
  const host=await generateKeyPair(), phone=await generateKeyPair(), other=await generateKeyPair(), c=context();
  const e=await seal(new Uint8Array(randomBytes(20)),c,host.publicKey,phone.privateKey);
  await assert.rejects(open(e,c,other.privateKey,phone.publicKey));
  await assert.rejects(open(e,c,host.privateKey,other.publicKey));
  for (const key of ['installationID','sessionID','operationID']) await assert.rejects(open(e,{...c,[key]:randomUUID()},host.privateKey,phone.publicKey));
  await assert.rejects(open(e,{...c,direction:'hostToPhone'},host.privateKey,phone.publicKey));
  await assert.rejects(open(e,c,host.privateKey,phone.publicKey,c.expiresAt*1000));
  const ct=Buffer.from(e.ciphertext,'base64'); ct[0]^=1;
  await assert.rejects(open({...e,ciphertext:ct.toString('base64')},c,host.privateKey,phone.publicKey));
});
test('oversize input and invalid wire data are rejected',async () => {
  const host=await generateKeyPair(), phone=await generateKeyPair(), c=context();
  await assert.rejects(seal(new Uint8Array(maximumPlaintextBytes+1),c,host.publicKey,phone.privateKey));
  const e=await seal(new Uint8Array(),c,host.publicKey,phone.privateKey);
  for(const bad of [{...e,version:2},{...e,encapsulatedKey:'!'},{...e,ciphertext:'AAAA'},{...e,context:{...c,expiresAt:NaN}}]) await assert.rejects(open(bad,c,host.privateKey,phone.publicKey));
});

test('maximum supported payload round trips', async () => {
  const host=await generateKeyPair(),phone=await generateKeyPair(),c=context();
  const input=new Uint8Array(randomBytes(maximumPlaintextBytes));
  const wire=await seal(input,c,host.publicKey,phone.privateKey);
  assert.deepEqual(await open(wire,c,host.privateKey,phone.publicKey),input);
});
