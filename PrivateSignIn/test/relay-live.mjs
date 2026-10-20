// Explicit local integration runner; requires npm run dev. No real credentials.
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import {hostRequest} from './relay-auth.test.mjs';
const base=process.env.OTTO_PRIVATE_PHONE_URL || process.env.MUSE_PRIVATE_PHONE_URL || 'http://127.0.0.1:8791';
function connect(url,headers={}){return new Promise((resolve,reject)=>{const ws=new WebSocket(url, {headers});ws.once('open',()=>resolve(ws));ws.once('error',reject);});}
function receive(ws){return new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('message timeout')),5000);ws.once('message',data=>{clearTimeout(timer);resolve(String(data));});});}
const h=await hostRequest(base);
const host=new WebSocket(h.url.href.replace(/^http/,'ws'),{headers:h.headers});
assert.equal(await receive(host),'ready');
const phoneURL=`${base.replace(/^http/,'ws')}/v1/phone/${h.id}/${h.session}`;
await assert.rejects(connect(phoneURL,{Origin:'https://wrong.example'}));
await assert.rejects(connect(h.url.href.replace(/^http/,'ws'),h.headers));
const phone=await connect(phoneURL,{Origin:base});
const forward=receive(host);phone.send(JSON.stringify({envelope:'synthetic ciphertext'}));
const packet=JSON.parse(await forward);assert.deepEqual(packet.payload,{envelope:'synthetic ciphertext'});
const response=receive(phone);host.send(JSON.stringify({peerID:packet.peerID,payload:{envelope:'synthetic response'}}));
assert.deepEqual(JSON.parse(await response),{envelope:'synthetic response'});
const close=new Promise(resolve=>phone.once('close',resolve));host.close();await close;host.terminate();phone.terminate();
await assert.rejects(connect(phoneURL,{Origin:base}));
const page=await fetch(base);assert.equal(page.status,200);assert.equal(page.headers.get('referrer-policy'),'no-referrer');assert.equal(page.headers.get('cache-control'),'no-store');
assert.equal((await fetch(base+'/?capability=invalid')).status,403);
console.log('PASS: relay routing, host replay, wrong origin, disconnect, and page privacy headers');
