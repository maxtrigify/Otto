// Local synthetic UI fixture. Keys stay in memory; no real account is involved.
import WebSocket from 'ws';
import {hostRequest} from './relay-auth.test.mjs';
import {generateKeyPair,exportPublicKey,importPublicKey,seal,open} from '../envelope.mjs';
const h=await hostRequest(undefined,Math.floor(Date.now()/1000)+300),key=await generateKeyPair(),cap=crypto.randomUUID();
const ws=new WebSocket(h.url.href.replace('http:','ws:'),{headers:h.headers});
const seen=new Set();let peer;
ws.on('message',async raw=>{
 try{
 if(String(raw)==='ready'){
 const link={version:1,installationID:h.id,sessionID:h.session,expiresAt:h.expiry,hostPublicKey:await exportPublicKey(key.publicKey),capability:cap};
 console.log('PREVIEW '+ 'http://127.0.0.1:8791/#'+Buffer.from(JSON.stringify(link)).toString('base64url'));return;}
 const packet=JSON.parse(String(raw)),p=packet.payload;
 const context={installationID:h.id,sessionID:h.session,operationID:p.envelope.context.operationID,direction:'phoneToHost',expiresAt:h.expiry};
 const pub=await importPublicKey(p.publicKey);const cmd=JSON.parse(new TextDecoder().decode(await open(p.envelope,context,key.privateKey,pub)));
 if(seen.has(context.operationID))throw Error();seen.add(context.operationID);
 if(!peer){if(cmd.action!=='claim'||cmd.capability!==cap)throw Error();peer=packet.peerID;}
 if(peer!==packet.peerID)throw Error();
 let view={mode:'consent',title:'Connect this website?',origin:'https://example.test',message:'Allow your agent to use this test website?'};
 if(cmd.action==='consent')view={mode:'form',title:'Sign in privately',origin:'https://example.test',message:'Synthetic test only.',form:{requests:[{id:h.session}],revision:'fixture-1',elements:[{id:'user',kind:'field',label:'Email'},{id:'password',kind:'secret',purpose:'password',label:'Password'},{id:'submit',kind:'button',label:'Sign in'}]}};
 if(cmd.action==='input'){if(cmd.input.fields.user!=='test@example.test'||cmd.input.fields.password!=='synthetic-test-only')throw Error();view={mode:'approval',title:'Allow this action?',origin:'https://example.test',message:'Click “Verify test”.'};console.log('PASS: encrypted form received');}
 if(['approve','deny','cancel'].includes(cmd.action)){view={mode:'complete',title:'You’re all set.',message:'Return to Messages. This was a local test.'};console.log('PASS: phone decision '+cmd.action);}
 ws.send(JSON.stringify({peerID:packet.peerID,payload:await seal(new TextEncoder().encode(JSON.stringify(view)),{...context,direction:'hostToPhone'},pub,key.privateKey)}));
 }catch{console.log('FAIL: invalid fixture request');ws.close();}
});
setTimeout(()=>{ws.terminate();},305000);
