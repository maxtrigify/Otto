# Otto Mobile Phase 0 foundation

## Scope

The first mobile slice keeps Otto execution on the Mac. The phone is a remote conversation client;
provider processes, sessions, repositories, files, credentials, tools, and canvas/browser ownership
remain in the existing Mac runtime. Cloud hosts and public networking are explicitly out of scope.

## Existing architecture

- `OttoModels` owns durable bot identity (`AgentProfile`), bot channels (`BotChannel`), canvas nodes,
  and provider resume identifiers. Mobile types belong here without changing those identities.
- `OttoRuntime.AgentSupervisor` owns live provider processes and readable runtime projections.
  `ProviderSessionStore` restores provider-owned transcript history from disk.
- `OttoPersistence.SQLiteWorkspaceStore` persists workspace/canvas/node snapshots and normalized
  session/run metadata. It is not currently a canonical transcript event store.
- `OttoRuntime.OttoEventBus` is an in-memory lifecycle feed. Its bounded process-local sequence is
  unsuitable as a reconnect cursor.
- `OttoRemote` is a lower-level authenticated PTY/file daemon with a machine-wide journal. It
  remains host-only and is not repurposed as the mobile thread protocol.
- `OttoServices.ApplicationServices` is the existing audited command boundary for sending prompts,
  interrupting, and stopping agents. A host adapter must delegate to it rather than launching or
  migrating provider sessions independently.

## Foundation implemented

1. Add platform-neutral `ExecutionEnvironment`, `Thread`, `ThreadMessage`, and `RunEvent` models to
   `OttoModels`. A thread references existing bot/channel/node identities and exactly one execution
   environment; it does not replace Bots or Sessions.
2. Add `OttoRPCContracts` with an explicit protocol version, typed method scopes, request/response
   envelopes, snapshots, delta pages, subscriptions, and idempotent `clientMessageID` sends.
3. Add `OttoHostRuntime` as a transport-independent local Mac host boundary. It owns a durable,
   per-thread append-only event journal, validates cursors and thread identity, and delegates all
   execution to a `OttoHostDataSource`.
4. Add an `ApplicationServices` adapter that projects existing bot channels and runtime snapshots,
   maps `conversationID` to the mobile thread ID, and sends replies through the existing audited
   `sendPrompt` path.
5. Completion/failure events carry a notification classification so APNs routing can be added
   without changing the event schema.

## Local vertical slice implemented

- `OttoMobileEventBridge` subscribes to the existing broadcast `OttoEventBus`, projects only
  structured transcript/lifecycle state (never raw PTY bytes), and appends it to the durable
  canonical journal. Its startup cursor is captured before transcript seeding so no event can fall
  between the snapshot and subscription.
- `OttoHostTransport` exposes the versioned contract over authenticated HTTP and WebSocket. It
  binds to loopback by default; LAN binding must be explicitly enabled and requires TLS. HTTP
  catch-up and WebSocket replay use the same per-thread journal cursor.
- `ApplicationServices` starts the host only when an explicit developer token is configured and
  continues to route sends, interrupts, and stops through the existing Mac-owned runtime.
- `OttoMobileClient` implements snapshot → delta catch-up → live stream, stable event-ID
  deduplication, strict sequence-gap recovery, idempotent reply sends, and reconnect backoff.
- `Apps/OttoMobileApp` is a minimal iPhone SwiftUI container with a developer pairing form, thread
  list, canonical event transcript, and reply composer. The visual language is intentionally a
  compact field notebook rather than a reduced copy of the Mac canvas.

### Developer host configuration

The host remains off unless `OTTO_MOBILE_HOST_TOKEN` contains at least 32 UTF-8 bytes.

- Loopback development: set `OTTO_MOBILE_HOST_TOKEN`; the host listens on `127.0.0.1:7338`.
- Physical iPhone/LAN development: also set `OTTO_MOBILE_HOST_ALLOW_LAN=1`, optionally set
  `OTTO_MOBILE_HOST_BIND` and `OTTO_MOBILE_HOST_PORT`, and provide PEM files through
  `OTTO_MOBILE_TLS_CERT` and `OTTO_MOBILE_TLS_KEY`.
- The health probe is `/health`, RPC is `/v1/rpc`, and the authenticated event socket is
  `/v1/events?thread_id=<uuid>&after=<sequence>`.

The typed token form is deliberately a developer bootstrap, not the production pairing design.
No credential, provider process, repository, file, or session is moved off the Mac.

## Simulator test loop

Install an official runtime once if `xcrun simctl list runtimes` is empty:

```sh
xcodebuild -downloadPlatform iOS
```

Then use two terminals from the repository root:

```sh
# Terminal 1: local sample thread and reconnect-safe event host
scripts/run-mobile-demo-host

# Terminal 2: create/boot the dedicated simulator, build, install, and launch the app
scripts/run-mobile-simulator
```

The simulator launcher injects the fixed local-only demo endpoint, token, and device ID into the
app process. They are not persisted. Open the Ada thread and send a reply; the demo host emits a
working state, assistant message, and completion event over the live socket. Running the simulator
launcher again exercises process relaunch and snapshot/cursor catch-up against the same host.

## Acceptance evidence (2026-08-28)

- The combined mobile contract, host runtime, transport, client, cache, push, gateway, and reconnect
  pack passed 24 tests across 10 suites.
- The native iPhone app built with Xcode 26.3 for the dedicated iOS 26.3 simulator.
- `OttoMobileAppUITests.testSendStreamsAndRelaunchesWithoutDuplicates` drove the real SwiftUI app
  against the local demo host: it opened Ada, loaded the canonical transcript, sent a unique reply,
  observed the streamed response, terminated the app, relaunched it, and proved the response was
  recovered exactly once.
- A retained native screenshot was visually reviewed after relaunch. The field-notebook hierarchy,
  live host context, recovered transcript, and pinned composer were all usable at iPhone size.
- Stable accessibility labels cover thread opening, the message composer, and send action so live
  timestamps cannot invalidate UI automation or VoiceOver targeting.

This evidence covers the simulator/loopback developer vertical slice. Physical-device LAN and
cross-network acceptance belong to the paired local-host alpha below; they are not claimed by this
Phase 0 checkpoint.

## Next executable step

Replace the developer token form with QR pairing: a short-lived, single-use Mac challenge; a
device-bound credential stored in Keychain; explicit revoke/list-device controls; and Bonjour host
discovery. Then route the already-classified completion/failure events to an APNs registration
boundary without adding cloud execution or changing the Bots/Sessions ownership model.
