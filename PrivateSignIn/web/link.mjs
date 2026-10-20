// Link secrets stay in the fragment, which is never sent in the HTTP request.
export function decodeLink(fragment) {
  if (fragment.length > 2048) throw new Error('Invalid link');
  if (!fragment.startsWith('v1.')) return JSON.parse(atob(fragment.replace(/-/g, '+').replace(/_/g, '/')));
  const encoded = fragment.slice(3).replace(/\./g, '');
  if (!/^[A-Za-z0-9_-]+$/.test(encoded)) throw new Error('Invalid link');
  const bytes = Uint8Array.from(atob(encoded.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));
  if (bytes.length !== 137) throw new Error('Invalid link');
  const uuid = start => {
    const hex = [...bytes.slice(start, start + 16)].map(b => b.toString(16).padStart(2, '0')).join('');
    return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
  };
  const base64 = (start, end) => btoa(String.fromCharCode(...bytes.slice(start, end)));
  return {version:1, installationID:uuid(0), sessionID:uuid(16),
    expiresAt:Number(new DataView(bytes.buffer).getBigUint64(32)),
    hostPublicKey:base64(40,105), capability:base64(105,137)};
}
