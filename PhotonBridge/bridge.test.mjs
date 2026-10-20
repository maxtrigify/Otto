import test from 'node:test';
import assert from 'node:assert/strict';
process.env.OTTO_PHOTON_UNIT_TEST = '1';
const {inbound} = await import('../Sources/OttoServices/Resources/PhotonBridge/bridge.mjs');
const space = {id:'chat',type:'dm',phone:'+15550002222'};
const message = {id:'guid', platform:'imessage',direction:'inbound',sender:{id:'+15550001111'}, content:{type:'text',text:'Hello'}};
test('authenticated SDK message preserves identity and correlation', () => {
  assert.deepEqual(inbound(space,message,x=>x,'project'), {kind:'inbound',accountID:'project',eventID:'guid',conversation:'chat',sender:'+15550001111',destination:'+15550002222',isDirect:true,text:'Hello',unsupported:false});
});
test('groups, outbound echoes, missing identities, and receipts ignored', () => {
  for(const bad of [{direction:'outbound'},{sender:undefined},{id:''},{platform:'telegram'},{content:{type:'read'}}]) assert.equal(inbound(space,{...message,...bad},x=>x,'project'),undefined);
  assert.equal(inbound({...space,type:'group'},message,x=>x,'project'),undefined);
});
test('attachment becomes explicit unsupported content', () => {
  const result=inbound(space,{...message,content:{type:'attachment'}},x=>x,'project');
  assert.equal(result.unsupported,true);assert.equal(result.text,'');
});
test('provider errors expose only safe categories', async () => {
  const {failureType} = await import('../Sources/OttoServices/Resources/PhotonBridge/bridge.mjs');
  assert.equal(failureType({status:401,message:'private'}),'credentialExpired');
  assert.equal(failureType({code:8,message:'private'}),'throttled');
  assert.equal(failureType(new Error('private')),'unavailable');
});
test('empty sender and routing phone fail closed', () => {
  assert.equal(inbound({...space,phone:''},message,x=>x,'project'),undefined);
  assert.equal(inbound(space,{...message,sender:{id:''}},x=>x,'project'),undefined);
});
test('send returns provider acceptance only with a message ID', async () => {
  const {deliver}=await import('../Sources/OttoServices/Resources/PhotonBridge/bridge.mjs');
  for(const [receipt,kind] of [[{id:'provider-id'},'accepted'],[undefined,'uncertain']]) {
    const outputs=[];
    await deliver({},()=>({space:{get:async()=>({send:async()=>receipt})}}),{id:'job',conversation:'chat',destination:'phone',text:'answer'},x=>outputs.push(x));
    assert.deepEqual(outputs,[{kind,id:'job'}]);
  }
});
test('pre-send lookup may retry; any error after send starts is uncertain', async () => {
  const {deliver}=await import('../Sources/OttoServices/Resources/PhotonBridge/bridge.mjs');
  for(const before of [true,false]) {
    const outputs=[];let sends=0;
    const narrow=()=>({space:{get:async()=>{
      if(before) throw {status:429};
      return {send:async()=>{sends++;throw new Error('lost response after acceptance');}};
    }}});
    await deliver({},narrow,{id:'job'},x=>outputs.push(x));
    assert.equal(outputs[0].kind,before?'retry':'uncertain');
    assert.equal(sends,before?0:1);
  }
});

test('read uses only the retained inbound message from the matching conversation', async () => {
  const {signal}=await import('../Sources/OttoServices/Resources/PhotonBridge/bridge.mjs');
  let reads=0; const original={id:'m'};
  const entries=new Map([['m',{space:{id:'chat',read:async m=>{assert.equal(m,original);reads++;}},message:original}]]);
  await signal({},null,{action:'read',eventID:'missing',conversation:'chat'},entries);
  assert.equal(reads,0);
  await signal({},null,{action:'read',eventID:'m',conversation:'chat'},entries);
  await signal({},null,{action:'read',eventID:'m',conversation:'chat'},entries);
  assert.equal(reads,1);
  assert.equal(entries.size,0);
});
test('typing starts and stops on the routed conversation and failures are best effort', async () => {
  const {signal}=await import('../Sources/OttoServices/Resources/PhotonBridge/bridge.mjs');
  const calls=[];
  const narrow=()=>({space:{get:async(id,options)=>{
    assert.equal(id,'chat');assert.equal(options.phone,'phone');
    return {startTyping:async()=>calls.push('start'),stopTyping:async()=>calls.push('stop')};
  }}});
  for(const action of ['typingStart','typingStop'])
    await signal({},narrow,{action,conversation:'chat',destination:'phone'},new Map());
  assert.deepEqual(calls,['start','stop']);
  await signal({},()=>{throw new Error('private');},{action:'typingStart'},new Map());
});
