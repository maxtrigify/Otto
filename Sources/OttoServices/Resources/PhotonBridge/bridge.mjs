// Private stdio only: never a public HTTP listener. Credentials arrive over stdin.
import readline from 'node:readline';
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
// SDK logs can contain account metadata. Keep stdout protocol-only and discard diagnostics.
console.log = console.info = console.warn = console.error = console.debug = () => {};
let app, imessage, account;
const received = new Map();
export function failureType(error) {
  if ([401, 403, 16, 7].includes(error?.status ?? error?.code)) return 'credentialExpired';
  if ([429, 8].includes(error?.status ?? error?.code)) return 'throttled';
  return 'unavailable';
}
export function inbound(space, message, narrow, accountID) {
  if (message.platform !== 'imessage' || message.direction !== 'inbound') return;
  const im = narrow(space);
  if (im.type !== 'dm' || !message.sender?.id || !message.id || !im.phone) return;
  if (['read', 'typing', 'reaction', 'edit', 'unsend'].includes(message.content.type)) return;
  return {kind:'inbound', accountID, eventID:message.id, conversation:space.id,
    sender:message.sender.id, destination:im.phone, isDirect:true,
    text:message.content.type === 'text' ? message.content.text : '',
    unsupported:message.content.type !== 'text'};
}
export async function deliver(app, imessage, c, emit) {
    if (!app) { emit({kind:'retry', id:c.id}); return; }
    // Lookup can fail before send. Once send starts, every error is uncertain.
    let space;
    try { space = await imessage(app).space.get(c.conversation, {phone:c.destination}); }
    catch (error) { emit({kind:'retry', id:c.id, reason:failureType(error)}); return; }
    try {
      const receipt = await space.send(c.text);
      emit({kind:receipt?.id ? 'accepted' : 'uncertain', id:c.id});
    } catch (error) { emit({kind:'uncertain', id:c.id, reason:failureType(error)}); }
}
// Best-effort UI feedback must not turn an accepted task into a connection failure.
export async function signal(app, imessage, c, received) {
  if (!app) return;
  try {
    if (c.action === 'read') {
      const entry = received.get(c.eventID);
      received.delete(c.eventID);
      if (entry && entry.space.id === c.conversation) await entry.space.read(entry.message);
    } else if (['typingStart', 'typingStop'].includes(c.action)) {
      const space = await imessage(app).space.get(c.conversation, {phone:c.destination});
      if (c.action === 'typingStart') await space.startTyping();
      else await space.stopTyping();
    }
  } catch { /* unsupported signals cannot interrupt request/response delivery */ }
}
async function command(c) {
  if (c.kind === 'connect') {
    const sdk = await import('spectrum-ts');
    ({imessage} = await import('spectrum-ts/providers/imessage'));
    account = c.accountID;
    app = await sdk.Spectrum({projectId:account, projectSecret:c.secret,
      providers:[imessage.config()], telemetry:false, options:{logLevel:'silent'}});
    emit({kind:'ready'});
    (async () => {
      for await (const [space, message] of app.messages) {
        const event = inbound(space, message, imessage, account);
        if (event) {
          received.set(message.id, {space, message});
          if (received.size > 128) received.delete(received.keys().next().value);
          emit(event);
        }
      }
      emit({kind:'offline'});
    })().catch(() => emit({kind:'offline'}));
  } else if (c.kind === 'signal') {
    let timeout;
    try {
      await Promise.race([signal(app, imessage, c, received), new Promise(resolve => { timeout = setTimeout(resolve, 3000); })]);
    } finally { clearTimeout(timeout); }
  } else if (c.kind === 'send') {
    await deliver(app, imessage, c, emit);
  } else if (c.kind === 'disconnect') {
    await app?.stop(); process.exit(0);
  }
}
// MUSE_PHOTON_UNIT_TEST is the pre-rename name of the same switch.
if (!process.env.OTTO_PHOTON_UNIT_TEST && !process.env.MUSE_PHOTON_UNIT_TEST) {
  const input = readline.createInterface({input:process.stdin, crlfDelay:Infinity});
  // Serialize commands; events continue concurrently. No secret or message echo on errors.
  for await (const line of input) {
    try { await command(JSON.parse(line)); }
    catch (error) { emit({kind:'connectionFailed', reason:failureType(error)}); }
  }
  await app?.stop();
}
