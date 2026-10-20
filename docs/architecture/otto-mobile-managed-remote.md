# Otto managed remote control plane

Phase 2 introduces a provider-neutral control plane between the paired iPhone and a Mac host. The
control plane does not run agents itself. It records account-scoped devices, advertises a stable
HTTPS environment endpoint, and issues short-lived signed tickets that bind one device to one
environment and an explicit set of scopes.

## Server configuration

The commercial server exposes managed-remote routes only when `OTTO_REMOTE_ENDPOINT_BASE_URL` is
set to an absolute HTTPS URL. Account provisioning is additionally disabled unless
`OTTO_REMOTE_ADMIN_TOKEN` is present.

```text
OTTO_REMOTE_ENDPOINT_BASE_URL=https://relay.example.com/
OTTO_REMOTE_ADMIN_TOKEN=<internal provisioning credential>
```

The server continues to require its normal PostgreSQL and Ed25519 signing configuration. Account,
device, one-time pairing-offer, environment, connector-credential, heartbeat, and revocation state are stored in PostgreSQL;
the active relay lease is intentionally process-local because it represents one live outbound socket,
not durable trust state.

The desktop can create iPhone pairing offers when these account values are present alongside the
connector configuration:

```text
OTTO_REMOTE_ACCOUNT_ID=<provisioned account UUID>
OTTO_REMOTE_ACCOUNT_CREDENTIAL=<account credential stored by the desktop>
```

The account credential stays on the Mac. The QR code contains only an opaque offer ID, a random
one-time secret, the control-plane URL, and its short expiry. It never contains the account or Mac
device credential.

## Otto Remote subscription boundary

Hosted relay access requires a signed entitlement containing the exact `managed_remote` feature.
Nearby loopback/LAN and private Tailscale pairing do not consult commercial state and remain local.
The Mac activates an already-purchased licence at `POST /v1/managed/subscription/activate`, stores
the returned refresh credential in Keychain, and can refresh it at
`POST /v1/managed/subscription/refresh`. `GET /v1/managed/subscription` returns only plan, feature,
state, and expiry metadata for the authenticated account.

The control plane stores the account's licence, plan, feature list, and online entitlement expiry.
It checks that boundary before creating a pairing offer, consuming an offer, and issuing every
short-lived connection ticket. Missing or expired access returns HTTP 402 without consuming the
offer or registering an iPhone. The Mac and iPhone translate that response into a product message
that names Otto Remote and explicitly points back to local/Tailscale pairing; they never expose a
raw HTTP code as the primary explanation. The server's online boundary uses `expiresAt`, not the
client-only offline grace window.

The desktop Mobile settings panel exposes missing, expired, and active states, licence activation,
Keychain-backed refresh, and the entitlement's valid-through date. A Remote Access QR is produced
only while the signed state is active. This is a direct-sale licence flow backed by the existing
commercial service; it is not a cosmetic local StoreKit flag.

## Mac connector

Otto and `otto-mobile-demo-host` start the production outbound connector when all four values are
present:

```text
OTTO_REMOTE_CONTROL_PLANE_URL=https://relay.example.com/
OTTO_REMOTE_CONNECTOR_CREDENTIAL=<one-time environment registration result>
OTTO_REMOTE_SIGNING_KEY_ID=<commercial Ed25519 key id>
OTTO_REMOTE_SIGNING_PUBLIC_KEY=<base64-encoded 32-byte Ed25519 public key>
```

`OTTO_REMOTE_CAPABILITIES` may override the default comma-separated `threads,runs` declaration.
Partial configuration fails closed. Plain HTTP is accepted only for loopback development; deployed
control planes must use HTTPS/WSS.

Before opening `GET /v1/managed/connectors?environment_id=<uuid>` as a WebSocket, the Mac posts an
authenticated heartbeat. It renews that heartbeat every 30 seconds while the socket remains open.
Only one connector lease may own an environment: a newer authenticated socket closes and replaces
the older one, and a stale disconnect cannot remove the newer lease.

The stable mobile RPC endpoint is `POST /v1/environments/<environment-id>/rpc`. Its body contains the
signed connection ticket and canonical `OttoRPCRequest`. The relay verifies signature, expiry,
environment, and method scope before forwarding. The Mac independently repeats those checks before
calling `OttoHostRuntime`, and correlates the response over the socket. Revocation is checked for
every forwarded request, so it closes access immediately without waiting for the socket to drop.

## Remote approvals

Mobile approvals use the dedicated `approval:respond` scope; read, message, and run-control tickets
cannot answer them. When the Mac provider blocks, the canonical event contains a typed request ID,
run ID, human-readable action, creation time, and random nonce. The iPhone may approve that exact
action once or deny it. The host compares both request ID and nonce against the first live pending
request before resuming the provider, then consumes it atomically. Stale, reordered, or replayed
responses fail as `approval_unavailable`.

Approvals are deliberately online-only. They are never placed in the mobile retry queue because a
provider prompt may have changed or disappeared while the phone was disconnected. Opening a thread
also calls `approval.get`, so a request remains actionable after an iPhone relaunch even when the
original attention event was already consumed. The card states the exact action and that approval
applies once on the Mac; it does not offer a durable “always allow” shortcut.

## Attachment transfer

Attachments remain workspace-owned files on the Mac. The iPhone first prepares an upload with the
thread ID, safe display name, MIME type, byte count, and SHA-256 digest. The Mac returns a random
15-minute upload ID and a 256 KB chunk size. Chunks must be contiguous and the complete transfer is
limited to 20 MB; an identical already-written chunk is accepted as a retry, while overlapping,
out-of-order, oversized, expired, or digest-mismatched data is rejected. The staged file uses mode
`0600` beneath the workspace's private `.otto/mobile-uploads` directory and is imported through the
existing `WorkspaceAttachmentStore` only after its final digest matches.

Upload methods require `message:write`; listing and downloading require `thread:read`. A completed
upload is attached exactly once to the existing Mac canvas node. Download uses the attachment ID
rather than a client-supplied path, revalidates containment, regular-file/no-symlink status, and the
stored byte count, then returns bounded chunks with the complete file's SHA-256 on the final chunk.
The iPhone verifies that digest before writing or exposing the file. It may choose an existing
document or create a text note, shows transfer progress and the resulting file chip, downloads it
into an app-private temporary directory, and exposes the native share sheet. No Mac absolute path
crosses the protocol.

## Privacy-safe Mac health

`diagnostics.get` requires `environment:read` and returns a dedicated allowlisted projection of the
Mac's existing local observability store. It contains app/OS versions, the previous-session crash
marker, aggregate tool/provider counts, median tool latency, and at most 50 typed local event rows.
The contract has no prompt, code, terminal-output, path, filename, browser-URL, attachment-content,
or voice-transcript field. The iPhone independently validates version characters, event vocabulary,
tool names, bounds, counts, and finite durations before displaying any response.

The Mac health sheet is read on demand rather than during ordinary conversation sync. It explains
the privacy boundary, makes crash recovery and failure counts actionable, and keeps the recent event
rows local to the screen. Preparing a support artifact is disabled until the user explicitly enables
the consent toggle. The artifact uses a separate aggregate-only schema with no event-row field, is
written under complete iOS file protection, and is not transmitted automatically; the user chooses
a destination through the native share sheet.

## HTTP lifecycle

JSON field names use lower camel case, matching the existing commercial service contract. Secrets
are returned once and must be stored in the platform keychain rather than logs or preferences.

1. `POST /v1/managed/accounts/provision` with `X-Muse-Admin-Token` returns an account and account
   credential.
2. `POST /v1/managed/devices` with the account credential registers a `mac_host` and returns a
   device credential.
3. `POST /v1/managed/pairing-offers` with the account credential creates a short-lived iPhone offer.
4. The iPhone scans the `otto://remote` QR and exchanges the offer ID plus one-time secret at
   `POST /v1/managed/pairing-offers/exchange`. The atomic consume-and-register transaction permits
   exactly one successful exchange, even across server processes. Expired, invalid, and replayed
   offers all return `410` without revealing which check failed.
5. The iPhone verifies the returned device credential with authenticated discovery before saving
   its device record and Curve25519 private key in a ThisDeviceOnly Keychain item. Subsequent app
   launches bootstrap from that record; the QR and account credential are not needed again.
6. `POST /v1/managed/environments` with the Mac device credential registers a stable environment
   endpoint and returns a connector credential.
7. `POST /v1/managed/environments/heartbeat` keeps the environment online for another 90 seconds.
8. `GET /v1/managed/environments?device_id=<uuid>` with an iPhone device credential returns only
   environments owned by the same account.
9. `POST /v1/managed/tickets` returns an Ed25519-signed ticket valid for 30–300 seconds. Claims bind
   account, device, environment, endpoint, scopes, nonce, issue time, and expiry.
10. `POST /v1/managed/devices/revoke` with the account credential immediately invalidates that
   device. Revoking a Mac also marks every environment hosted by it offline.

Authentication failures deliberately return the same generic `401` response. Offline environments
return `503`, malformed requests return `400`, and successful revocation returns `204`.

## Verification

`managedRemoteHTTPLifecycle` runs the complete lifecycle over a real ephemeral Hummingbird server,
including missing-admin rejection, environment heartbeat, signed-ticket verification, revocation,
and rejection of the revoked phone credential. A hands-on smoke pass should also launch the actual
`otto-commercial-server` product against a disposable PostgreSQL database and drive these endpoints
with an independent HTTP client; do not use the shared Swift request encoder for that pass. The
restart canary must reuse the original phone and connector credentials after one server restart,
then prove a revoked phone remains rejected after a second restart.

`ManagedRemoteWebSocketTests` exercises the live WebSocket upgrade and stable HTTP endpoint,
including no-connector, insufficient-scope, and post-disconnect behavior.
`ManagedRemoteHostConnectorTests` uses the production `URLSessionWebSocketTask` connector, verifies
periodic heartbeat renewal, and proves a canonical RPC response crosses the real socket.

`PostgresCommercialIntegrationTests` persists the offer, reconstructs the registry to simulate a
server restart, races two exchanges, and requires exactly one device credential to be issued.
`Server/scripts/test-managed-mobile-pairing-e2e` (private server package) launches a real loopback control plane, relay connector,
demo host, and iPhone Simulator. It pairs from the one-time QR, sends a canonical message through
the managed relay, terminates the app, relaunches with no pairing launch arguments, and requires the
reply to recover exactly once from the Keychain-backed device record. The mobile event stream
currently polls the stable endpoint once per second and obtains a fresh scoped ticket per request;
this is intentionally functional but is an interim transport until the later push/stream phase.
The same managed E2E then triggers a typed host approval, taps **Approve once** in the real iPhone
UI, and requires the Mac-side demo action to resume through the relay. Runtime, host-contract, and
client-store tests separately prove wrong-nonce and replay rejection. It then creates a text note
through the production iPhone UI, uploads it through the managed relay, downloads the same bytes,
and requires the native share action. A 600 KB service integration fixture separately crosses three
chunks, retries one chunk, verifies the digest, imports exactly once, and reassembles the download.
The mobile client suite also supplies a false final download digest and requires the transfer to
fail closed without producing a shareable file.
Running the same topology with `OTTO_MANAGED_REMOTE_E2E_EXPIRED=1` creates a pairing offer while the
entitlement is active, lets it expire, and then drives the real iPhone confirmation button. The
exchange must return the actionable Otto Remote explanation, must keep local/Tailscale fallback
visible, must not open the environment, and must not persist a device credential.
The managed topology then returns to the home screen, opens **Mac health**, reads a simulated
abnormal-session marker and allowlisted tool event through the relay, proves report creation is
disabled before consent, and prepares an aggregate-only report after consent. The captured
Simulator artifact is inspected to confirm it contains only versions, aggregate counts, latency,
and the crash marker.

The Phase 2B hands-on canary launches the actual PostgreSQL-backed commercial server and the
canonical demo `OttoHostRuntime`, then independently drives roster, thread, snapshot, and message
RPCs through the stable endpoint. Keep the socket open for more than 90 seconds and require another
successful RPC plus `online` discovery afterward. Finally revoke the Mac and require the next RPC to
return `503`.
