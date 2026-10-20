import test from 'node:test';
import assert from 'node:assert/strict';
import {installationID,verifyHost} from '../relay-auth.mjs';
export async function hostRequest(origin='http://127.0.0.1:8791',expiry=Math.floor(Date.now()/1000)+120){
 const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
 const raw=new Uint8Array(await crypto.subtle.exportKey('raw',keys.publicKey));
 const id=await installationID(raw),session=crypto.randomUUID(),time=String(Math.floor(Date.now()/1000)),nonce=crypto.randomUUID();
 const url=new URL(`/v1/host/${id}/${session}/${expiry}`,origin);
 const message=new TextEncoder().encode(['muse-phone-host-v1',url.origin,url.pathname,time,nonce].join('\n'));
 const signature=await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},keys.privateKey,message);
 const headers={'X-Muse-Time':time,'X-Muse-Nonce':nonce,'X-Muse-Key':Buffer.from(raw).toString('base64'),'X-Muse-Signature':Buffer.from(signature).toString('base64')};
 return {url,headers,id,session,expiry};
}
test('host proof binds installation, endpoint, time and nonce',async()=>{
 const h=await hostRequest();const request=new Request(h.url,{headers:h.headers});
 assert.equal(await verifyHost(request,h.id),true);
 assert.equal(await verifyHost(request,crypto.randomUUID()),false);
 assert.equal(await verifyHost(request,h.id,Date.now()+60000),false);
 for(const url of [h.url.href.replace(h.session,crypto.randomUUID()),h.url.href.replace('127.0.0.1','localhost')])assert.equal(await verifyHost(new Request(url,{headers:h.headers}),h.id),false);
 for(const key of Object.keys(h.headers))assert.equal(await verifyHost(new Request(h.url,{headers:{...h.headers,[key]:'invalid'}}),h.id),false);
});
