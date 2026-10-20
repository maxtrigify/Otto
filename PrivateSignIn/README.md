# Private phone sign-in

Otto sends a short-lived private link directly to the paired Messages conversation.
The phone page connects to the requesting Mac, asks for website consent or an exact
action approval, and carries password/MFA input outside agent and chat transcripts.
The Mac must be running and online. There is no end-user Cloudflare account or port setup.

## Deployment status

The hosted service runs at https://muse-private-sign-in.muse-private.workers.dev. The worker
name, URL, `X-Muse-*` headers and `muse-*-v1` crypto labels predate the Otto rename and are
legacy wire names: do not change them without a protocol version bump.
Both packaged app plists include that public origin. Operator authentication is stored
in the OS Keychain. Public relay routing and Swift encrypted exchange are verified;
actual phone and clean-install acceptance are recorded separately, not inferred from deployment.

## Development and verification

```
npm ci --ignore-scripts
npm test
npm run build
npm run dev
```

With the local worker running on port 8791, run `node test/relay-live.mjs` for
routing, origin, replay, disconnection and response-header checks. The synthetic
`node test/phone-preview.mjs` fixture exercises the actual page with in-memory keys.
It is not a real website login or production credential receiver.

From the repository root:

```
OTTO_PHONE_SOURCE_ROOT="$PWD" OTTO_PHONE_RELAY_TEST=1 OTTO_PHONE_INTEROP_TEST=1 OTTO_PRIVATE_PHONE_URL=http://127.0.0.1:8791 scripts/otto-swift test --filter 'PrivatePhone|WebsiteAccount|WebsiteCredentialVault'
```

The relay integration test is explicitly enabled and requires the local worker.
The other unit tests run without a server. `scripts/test-private-phone-protocol`
also runs the isolated crypto and ledger tests without a full app rebuild.

## Operator setup

1. Authenticate Wrangler to Otto's Cloudflare account. Use the Free plan for staging.
2. `npm run deploy` publishes the static bundle and SQLite Durable Object worker.
3. Set `OTTO_PRIVATE_PHONE_URL` to the resulting HTTPS origin while packaging Otto.
   Packaging scripts stamp it into Info.plist before signing. Ship that configuration
   in the app; never ask users to supply it. Debug builds alone accept a loopback URL.
4. Test a newly installed app and actual iPhone on separate networks before release.

Free-tier quotas and per-location rate limits are finite. This configuration does
not promise unlimited zero-cost hosting or automatic paid upgrades. Quota exhaustion
fails the feature closed. Monitor usage and decide capacity before broad distribution.

## Security boundaries

Each Mac creates an installation signing key in Keychain. Its installation ID is
derived from that public key. Signed host upgrades bind origin, path, timestamp and
nonce; a session tombstone prevents reconnect/replay until expiry. The relay stores
only temporary session expiry metadata, forwards bounded ciphertext and hibernates
idle sockets. Production observability is disabled. Static responses disable caching,
referrers, third-party resources and framing. WebSocket origin is explicit for WebKit.

The Mac creates a five-minute capability and ephemeral HPKE key per request. The
link carries these public/authorization values in its fragment, which the page removes
before connection. Opening or previewing a link does not claim it. On explicit Continue,
the browser proves the capability inside an authenticated encrypted envelope, and the
Mac binds the session to that browser key. A copied unclaimed link is a bearer capability;
protect the message thread. The first-party frontend is trusted code and must be protected
against modification; encryption does not make a malicious frontend harmless.

Authenticated HPKE uses P-256/HKDF-SHA256/AES-256-GCM with a fresh context per envelope.
Expected install/session/operation/direction/expiry are authenticated. The in-memory
ledger consumes operations before execution, limits sessions and rejects replays.
The owning job, run, bot grant and exact website origin/revision are rechecked.
Disconnect, restart, cancellation and uncertain sends never automatically replay an action.

Saved passwords require explicit phone consent and a confirmed sign-in. A dedicated
Keychain-only vault scopes entries to owner/workspace/account/origin. MFA values are
never saved. The internal autofill path requires the previously approved form signature,
current grant and previously confirmed distinct success URL. Changed or unsupported
forms return to private sign-in. The vault exposes no model-readable password tool.
Disconnect revokes grants before credential and cookie cleanup, allowing a failed cleanup
to be retried without retaining bot access.

Same-origin forms are supported initially. SSO popups, passkeys, CAPTCHA and arbitrary
custom fields are not claimed supported. Generic non-website agent permissions retain
the existing Otto approval UI; this channel handles website access and account clicks.

Exact dependency `@hpke/core` 1.9.0 (MIT) is bundled locally with lockfile integrity.
The maintainer reports no formal audit; the <=1.7.4 nonce-reuse advisory was fixed in
1.7.5.
