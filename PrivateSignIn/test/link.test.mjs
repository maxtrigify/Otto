import test from 'node:test';
import assert from 'node:assert/strict';
import {decodeLink} from '../web/link.mjs';
test('compact fragment preserves route, expiry, pinned key and capability',()=>{
 const b=Buffer.alloc(137); b.fill(17,0,16); b.fill(34,16,32); b.writeBigUInt64BE(1800000000n,32);b.fill(3,40,105);b.fill(4,105);
 const fragment='v1.'+b.toString('base64url').match(/.{1,64}/g).join('.');
 const link=decodeLink(fragment);
 assert.equal(link.installationID,'11111111-1111-1111-1111-111111111111');
 assert.equal(link.sessionID,'22222222-2222-2222-2222-222222222222');
 assert.equal(link.expiresAt,1800000000);
 assert.equal(link.hostPublicKey,Buffer.alloc(65,3).toString('base64'));
 assert.equal(link.capability,Buffer.alloc(32,4).toString('base64'));
 assert.throws(()=>decodeLink(fragment.slice(0,-8)));
 assert.throws(()=>decodeLink('v1.!'));
});
test('previous links remain readable',()=>{
 const legacy={version:1,sessionID:'example'};
 assert.deepEqual(decodeLink(Buffer.from(JSON.stringify(legacy)).toString('base64url')),legacy);
});
