import {decodeLink} from './link.mjs';
import {generateKeyPair,exportPublicKey,importPublicKey,seal,open} from '../envelope.mjs';
const $=id=>document.getElementById(id),encoder=new TextEncoder(),decoder=new TextDecoder();
let link,keys,hostKey,socket,pending,busy=false,closed=false,remember=false;
const clear=()=>document.querySelectorAll('input:not([type=checkbox])').forEach(input=>{input.value='';});
function fail(message){clear();closed=true;socket?.close();$('title').textContent='Let’s try again.';$('message').textContent=message;$('message').className='error';$('content').replaceChildren();}
function button(label,fn,secondary=false){const b=document.createElement('button');b.type='button';b.textContent=label;b.className=secondary?'secondary':'';b.onclick=fn;return b;}
function setBusy(value){busy=value;document.querySelectorAll('button,input').forEach(e=>e.disabled=value);}
function context(operationID,direction){return{installationID:link.installationID,sessionID:link.sessionID,operationID,direction,expiresAt:link.expiresAt};}
async function send(action,extra={}){
  if(busy||closed)return;setBusy(true);
  try{
    const id=crypto.randomUUID();
    const body={action,...extra};
    const encoded=encoder.encode(JSON.stringify(body));clear();
    const envelope=await seal(encoded,context(id,'phoneToHost'),hostKey,keys.privateKey);encoded.fill(0);
    const timer=setTimeout(()=>fail('The reply was interrupted. Ask your agent for a fresh link. Your action will not be repeated automatically.'),45000);
    pending={id,timer};
    socket.send(JSON.stringify({publicKey:await exportPublicKey(keys.publicKey),envelope}));
  }catch{fail('This private connection ended. Ask your agent for a new link.');}
}
function render(view){
  setBusy(false);$('site').textContent=view.origin||'PRIVATE REQUEST';$('title').textContent=view.title||'Sign in privately';$('message').textContent=view.message||'';$('message').className='';$('content').replaceChildren();
  if(view.mode==='complete'){closed=true;socket.close();return;}
  if(view.mode==='consent'){$('content').append(button('Allow & continue',()=>send('consent')),button('Not now',()=>send('cancel'),true));return;}
  if(view.mode==='approval'){$('content').append(button('Approve',()=>send('approve')),button('Deny',()=>send('deny'),true));return;}
  const output=view.form;
  if(!output||!Array.isArray(output.elements)||output.elements.length>200){fail('This sign-in page isn’t supported yet.');return;}
  const form=document.createElement('form');form.onsubmit=e=>e.preventDefault();const inputs=new Map();
  for(const field of output.elements.filter(f=>['field','secret','password','otp'].includes(f.kind))){
    const label=document.createElement('label');label.textContent=field.label;label.htmlFor='field-'+field.id;
    const input=document.createElement('input');input.id=label.htmlFor;input.name=field.id;input.maxLength=16384;
    input.type=['secret','password','otp'].includes(field.kind)?'password':'text';
    input.autocomplete=field.purpose==='password'?'current-password':field.purpose==='otp'?'one-time-code':'off';
    input.spellcheck=false;input.autocapitalize='none';if(field.purpose==='otp')input.inputMode='numeric';
    inputs.set(field.id,input);form.append(label,input);
  }
  if(output.elements.some(f=>f.purpose==='password')){
    const label=document.createElement('label');label.className='remember';const box=document.createElement('input');box.type='checkbox';box.checked=remember;box.onchange=()=>remember=box.checked;label.append(box,document.createTextNode('Remember securely on my Mac'));form.append(label);
  }
  for(const action of output.elements.filter(f=>f.kind==='button'))form.append(button(action.label,()=>{
    const fields=Object.fromEntries([...inputs].filter(([,input])=>input.value.length).map(([id,input])=>[id,input.value]));
    send('input',{input:{action:'click',requestID:output.requests[0]?.id,revision:output.revision,elementID:action.id,fields},remember});
  }));
  if(!output.elements.some(f=>['secret','password','otp'].includes(f.kind)))form.append(button('I’m signed in — continue',()=>send('finish')));
  form.append(button('Cancel',()=>send('cancel'),true));$('content').append(form);
}
async function start(){
  setBusy(true);
  try{
    keys=await generateKeyPair();hostKey=await importPublicKey(link.hostPublicKey);
    socket=new WebSocket(location.origin.replace(/^http/,'ws')+'/v1/phone/'+link.installationID+'/'+link.sessionID);
    const timer=setTimeout(()=>fail('Your Mac isn’t available. Try a fresh link when Otto is online.'),15000);
    socket.onopen=()=>{clearTimeout(timer);setBusy(false);const capability=link.capability;delete link.capability;send('claim',{capability});};
    socket.onmessage=async event=>{
      if(!pending||closed)return;
      try{
        if(typeof event.data!=='string'||event.data.length>100000)throw new Error();
        const current=pending;const plain=await open(JSON.parse(event.data),context(current.id,'hostToPhone'),keys.privateKey,hostKey);
        if(pending!==current||closed)return;
        clearTimeout(current.timer);pending=null;const view=JSON.parse(decoder.decode(plain));plain.fill(0);render(view);
      }catch{fail('The private reply could not be verified. Ask for a new link.');}
    };
    socket.onerror=()=>{clearTimeout(timer);if(!closed)fail('Your Mac isn’t available. Ask your agent for a fresh link.');};
    socket.onclose=()=>{clearTimeout(timer);if(!closed)fail('This connection ended. Ask your agent for a fresh link.');};
  }catch{fail('This link could not be opened. Ask your agent for a fresh one.');}
}
document.addEventListener('visibilitychange',()=>{if(document.hidden)clear();});
window.addEventListener('pagehide',()=>{clear();closed=true;socket?.close();});
try{
  const fragment=location.hash.slice(1);history.replaceState(null,'',location.pathname);
  if(fragment){
    if(fragment.length>2048)throw new Error();
    link=decodeLink(fragment);
    const uuid=/^[0-9a-f-]{36}$/;
    if(link.version!==1||!uuid.test(link.installationID)||!uuid.test(link.sessionID)||!Number.isSafeInteger(link.expiresAt)||link.expiresAt*1000<=Date.now()||link.expiresAt*1000>Date.now()+305000)throw new Error();
    $('message').textContent='Connect privately to Otto on your Mac. Your agent will continue once you’re signed in.';
    $('content').append(button('Continue securely',start));
  }
}catch{fail('This link has expired or is incomplete. Ask your agent for a new one.');}
