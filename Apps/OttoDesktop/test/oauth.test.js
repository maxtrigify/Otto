// Google sign-in's loopback listener: only the callback carrying the engine's state finishes it.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { LoopbackSignIn } = require('../src/oauth');

const get = async (port, path) => {
  const response = await fetch(`http://127.0.0.1:${port}${path}`);
  return { status: response.status, body: await response.text() };
};

test('the callback with the right state finishes sign-in; forged ones are refused', async () => {
  const seen = [];
  const replies = [];
  let browsing;
  const signIn = new LoopbackSignIn({
    open: (url) => (browsing = (async () => {
      seen.push(url);
      const port = signIn.lastPort;
      replies.push(await get(port, '/oauth2callback?state=wrong&code=evil'));
      replies.push(await get(port, '/elsewhere?state=s1&code=evil'));
      replies.push(await get(port, '/oauth2callback?state=s1&state=s1&code=evil'));
      replies.push(await get(port, '/oauth2callback?state=s1&code=good'));
    })()),
  });
  const { port } = await signIn.listen();
  signIn.lastPort = port;
  const result = await signIn.callback({ url: 'https://accounts.google.com/o/oauth2/v2/auth?x=1', state: 's1', port, timeoutSeconds: 10 });
  assert.equal(result.request, '/oauth2callback?state=s1&code=good');
  await browsing; // the browser's own requests finish after sign-in completes
  assert.deepEqual(replies.map((reply) => reply.status), [400, 400, 400, 200]);
  assert.match(replies[3].body, /Return to Otto/);
  assert.equal(seen.length, 1);
  await assert.rejects(get(port, '/oauth2callback?state=s1&code=again'), 'the listener closes after one sign-in');
});

test('only Google sign-in addresses are opened, and an unfinished sign-in times out', async () => {
  const signIn = new LoopbackSignIn({ open: async () => {} });
  const { port } = await signIn.listen();
  assert.throws(() => signIn.callback({ url: 'https://evil.example/', state: 's', port }), /Not a Google/);
  await assert.rejects(signIn.callback({ url: 'https://accounts.google.com/x', state: 's', port, timeoutSeconds: 0.2 }), /timed out/);
});
