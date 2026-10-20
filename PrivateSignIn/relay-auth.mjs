const encoder = new TextEncoder();
export const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export function decode64(value, length) {
  if(typeof value!=='string' || value.length!==Math.ceil(length/3)*4) throw new Error('Denied');
  const bytes=Uint8Array.from(atob(value),c=>c.charCodeAt(0));
  if(bytes.length!==length) throw new Error('Denied'); return bytes;
}
export async function installationID(publicKey) {
  const hash=new Uint8Array(await crypto.subtle.digest('SHA-256',publicKey));
  const hex=[...hash.subarray(0,16)].map(n=>n.toString(16).padStart(2,'0')).join('');
  return [hex.slice(0,8),hex.slice(8,12),hex.slice(12,16),hex.slice(16,20),hex.slice(20)].join('-');
}
// X-Muse-Time / X-Muse-Nonce / X-Muse-Key / X-Muse-Signature and 'muse-phone-host-v1' are
// legacy wire names, do not change without a protocol version bump: deployed Otto (and Muse)
// hosts sign with exactly these.
export async function verifyHost(request, id, now=Date.now()) {
  try {
    const url=new URL(request.url),time=request.headers.get('X-Muse-Time'),nonce=request.headers.get('X-Muse-Nonce');
    if(!/^\d{10}$/.test(time||'') || Math.abs(Number(time)*1000-now)>30000 || !uuidPattern.test(nonce||'')) return false;
    const raw=decode64(request.headers.get('X-Muse-Key'),65);
    if(await installationID(raw)!==id) return false;
    const key=await crypto.subtle.importKey('raw',raw,{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
    const message=encoder.encode(['muse-phone-host-v1',url.origin,url.pathname,time,nonce].join('\n'));
    return await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},key,decode64(request.headers.get('X-Muse-Signature'),64),message);
  } catch {return false;}
}
