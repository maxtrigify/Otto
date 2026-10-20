// Called by Swift tests through private pipes. Ephemeral test keys never go to files/logs.
import {CipherSuite,DhkemP256HkdfSha256,HkdfSha256,Aes256Gcm} from '@hpke/core';
import {createHash} from 'node:crypto';
import {generateKeyPair,exportPublicKey,importPublicKey,seal,open} from '../envelope.mjs';
const suite=new CipherSuite({kem:new DhkemP256HkdfSha256(),kdf:new HkdfSha256(),aead:new Aes256Gcm()});
let input=''; for await(const chunk of process.stdin) input+=chunk;
const v=JSON.parse(input);
if(v.action==='seal') {
  const keys=await generateKeyPair();
  const envelope=await seal(new Uint8Array(Buffer.from(v.plaintext,'base64')),v.context,await importPublicKey(v.hostPublicKey),keys.privateKey);
  process.stdout.write(JSON.stringify({envelope,publicKey:await exportPublicKey(keys.publicKey),privateKey:Buffer.from(await suite.kem.serializePrivateKey(keys.privateKey)).toString('base64')}));
} else if(v.action==='open') {
  const key=await suite.kem.deserializePrivateKey(new Uint8Array(Buffer.from(v.privateKey,'base64')));
  const plaintext=await open(v.envelope,v.envelope.context,key,await importPublicKey(v.hostPublicKey));
  process.stdout.write(JSON.stringify({digest:createHash('sha256').update(plaintext).digest('hex')}));
} else { process.exitCode=1; }
