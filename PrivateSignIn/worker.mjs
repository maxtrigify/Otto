import {DurableObject} from 'cloudflare:workers';
import {verifyHost,uuidPattern} from './relay-auth.mjs';
const headers={'Cache-Control':'no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff',
  'Content-Security-Policy':"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  'Permissions-Policy':'camera=(), microphone=(), geolocation=()','Strict-Transport-Security':'max-age=31536000'};
const fail=(status=403)=>new Response('Private sign-in is unavailable.',{status,headers});
export default {async fetch(request,env) {
  const url=new URL(request.url);
  if(url.search) return fail();
  if(url.pathname.startsWith('/v1/')) {
    if(request.method!=='GET'||request.headers.get('Upgrade')?.toLowerCase()!=='websocket')return fail();
    if(!env.IP_LIMIT || !env.GLOBAL_LIMIT) return fail(503);
    const ip=request.headers.get('CF-Connecting-IP')||'local';
    if(!(await env.IP_LIMIT.limit({key:ip})).success || !(await env.GLOBAL_LIMIT.limit({key:'private-input'})).success)return fail(429);
    const parts=url.pathname.split('/');
    const [,version,role,id,session,expiry]=parts;
    if(version!=='v1'||!['host','phone'].includes(role)||!uuidPattern.test(id||'')||!uuidPattern.test(session||'')||
      (role==='host'?parts.length!==6:parts.length!==5))return fail();
    if(role==='host') {
      if(!/^\d{10}$/.test(expiry||'')||Number(expiry)*1000<=Date.now()||Number(expiry)*1000>Date.now()+305000||!await verifyHost(request,id))return fail();
    } else if(request.headers.get('Origin')!==url.origin)return fail();
    return env.ROOMS.getByName(id).fetch(request);
  }
  if(!['GET','HEAD'].includes(request.method)||!['/','/index.html','/app.js','/style.css'].includes(url.pathname))return fail(404);
  const asset=await env.ASSETS.fetch(request);
  const result=new Response(asset.body,asset);for(const[k,v]of Object.entries(headers))result.headers.set(k,v);
  result.headers.set('Content-Security-Policy',headers['Content-Security-Policy'].replace("connect-src 'self'","connect-src 'self' "+url.origin.replace(/^http/,'ws')));return result;
}};

export class PrivateInputRoom extends DurableObject {
  constructor(ctx,env){super(ctx,env);this.ctx=ctx;ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping','pong'));}
  async fetch(request){
    const [, ,role,installation,session,expiry]=new URL(request.url).pathname.split('/');
    return this.ctx.blockConcurrencyWhile(async()=>{
      await this.cleanup();
      const record=await this.ctx.storage.get(session);
      if(role==='host'){
        if(record || (await this.ctx.storage.list()).size>=16)return fail(409);
        await this.ctx.storage.put(session,{expiresAt:Number(expiry)*1000});
        const alarm=await this.ctx.storage.getAlarm();
        if(alarm===null||alarm>Number(expiry)*1000)await this.ctx.storage.setAlarm(Number(expiry)*1000);
      } else if(!record || !this.ctx.getWebSockets('host:'+session).length || this.ctx.getWebSockets('phone:'+session).length>=3)return fail(410);
      const pair=new WebSocketPair(),[client,server]=Object.values(pair);
      this.ctx.acceptWebSocket(server,[role+':'+session]);
      server.serializeAttachment({role,installation,session,peerID:crypto.randomUUID(),expiresAt:role==='host'?Number(expiry)*1000:record.expiresAt,count:0});
      if(role==='host')server.send('ready');
      return new Response(null,{status:101,webSocket:client});
    });
  }
  webSocketMessage(ws,message){
    const a=ws.deserializeAttachment();
    if(!a||Date.now()>=a.expiresAt||typeof message!=='string'||message.length>100000||++a.count>256){ws.close(1008,'Session ended');return;}
    ws.serializeAttachment(a);
    try{
      const value=JSON.parse(message);
      if(a.role==='phone'){
        const hosts=this.ctx.getWebSockets('host:'+a.session);
        if(hosts.length!==1)throw new Error();
        // Ciphertext only. The Mac authenticates capability and peer; relay cannot authorize it.
        hosts[0].send(JSON.stringify({peerID:a.peerID,payload:value}));
      }else{
        if(typeof value.peerID!=='string')throw new Error();
        const peer=this.ctx.getWebSockets('phone:'+a.session).find(p=>p.deserializeAttachment().peerID===value.peerID);
        if(peer)peer.send(JSON.stringify(value.payload));
      }
    }catch{ws.close(1008,'Session ended');}
  }
  webSocketClose(ws){const a=ws.deserializeAttachment();if(a?.role==='host')for(const peer of this.ctx.getWebSockets('phone:'+a.session))peer.close(1001,'Mac disconnected');}
  webSocketError(ws){this.webSocketClose(ws);ws.close(1011,'Session ended');}
  async cleanup(){
    const records=await this.ctx.storage.list();let next=Infinity;
    for(const[id,record]of records){if(record.expiresAt<=Date.now()){
      for(const role of ['host','phone'])for(const ws of this.ctx.getWebSockets(role+':'+id))ws.close(1000,'Session expired');
      await this.ctx.storage.delete(id);
    }else next=Math.min(next,record.expiresAt);}
    if(Number.isFinite(next))await this.ctx.storage.setAlarm(next);else await this.ctx.storage.deleteAlarm();
  }
  async alarm(){await this.cleanup();}
}
