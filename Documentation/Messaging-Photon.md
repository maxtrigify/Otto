# Experimental iMessage messaging through a user-owned Photon project

Implementation contract: `Plans/muse-messaging-implementation-brief-2026-09-09.md` in Muse Workspace.

## Setup

Open Settings → Messaging. Install Node.js 22 or later on the host, then click **Install Photon connector**. This installs the pinned Spectrum SDK into this user's Application Support folder with npm lifecycle scripts disabled. It creates no provider account, purchases no service and starts no hosted infrastructure.

Click **Connect iMessage**. Sign in to your own existing Photon account in its dashboard. Copy the existing project's ID and secret from its Settings. Configure your phone as a user in that project and copy the assigned destination displayed by Photon. Enter those details in Otto, select a team in the current Otto project, and check its coordinator. Credentials go directly into the system Keychain, including debug builds. Otto never asks for an Apple ID password.

Otto uses the dashboard project-credential flow documented in Photon's SDK quickstart. It does not impersonate `photon-cli` to obtain device authorization. A first-party Otto device-login client would require provider registration/confirmation; it is not necessary for the supported project-credential path implemented here.

Send the generated `PAIR …` message from the configured phone to the assigned destination within five minutes. The token can be used once, and is invalidated by a restart, replacement or disconnect. Only an authenticated inbound SDK event can bind the sender and conversation. Send another text to test the selected team. A successful exchange means Photon returned an outbound message ID, **not** that the handset confirmed receipt.

Disconnect stops local transport, removes the Keychain secret, invalidates pairing, and cancels undelivered work. History remains. Project-secret remote revocation is left to the owner in Photon's dashboard; Otto does not delete a project, its users, or its lines. Reconnect reuses the local Keychain credential. To change account/team/project, disconnect and pair again, creating a separate conversation.

## Boundaries and recovery

- One installation-level connection, explicitly bound to the currently opened project. Opening another project pauses routing rather than silently rerouting it.
- The binding contains connection ID, provider project/account ID, expected and verified sender, destination, conversation ID, project path, team and coordinator. A shared destination alone is never identity.
- Acceptance and enqueue share one atomic, user-only JSON file in Application Support. A namespaced provider event key deduplicates authenticated inbound requests across restarts.
- Pairing stores only an in-memory digest. The token and secret are absent from JSON history and diagnostics.
- A separate Otto team channel per binding preserves team history isolation. The existing team runtime executes requests with existing profile permissions and internal tools. Direct specialist mentions cannot bypass coordinator routing on this channel. A specialist completion hands back for coordinator synthesis; only the final coordinator result is eligible for outbound delivery.
- The persisted job UUID is also the team user-message UUID. Dispatch and the existing team checkpoint live in different stores. A crash in that boundary is reconciled conservatively: accepted work is never blindly launched again, and ambiguous dispatch needs desktop review. This is not an exactly-once transaction across a provider/model boundary.
- Queued work resumes. In-flight model work uses the existing team checkpoint/review behavior. In-flight sends become uncertain after restart, transport loss or timeout. Unknown send outcomes are never automatically retried.
- Only failures known to occur before `space.send` get up to four attempts with bounded backoff. SDK send failures remain uncertain, including a possible provider acceptance followed by a lost local response.
- Text only, personal DMs only. Unknown senders, group events and outbound echoes do not invoke agents. Unsupported content from a paired sender gets an explanatory text response. Approval actions remain in Otto.
- Routine SDK stdout/stderr is suppressed, telemetry is disabled, and private protocol frames are not logged. Credentials travel over stdin, not argv or environment.

## Provider findings verified 9 September 2026

Primary references inspected:

- [Photon SDK quickstart](https://photon.codes/docs/spectrum-ts/getting-started): dashboard project ID/secret credentials, `Spectrum`, `app.messages`, and `space.send`.
- [iMessage connection and routing](https://photon.codes/docs/spectrum-ts/providers/imessage/connection-and-routing): managed outbound gRPC, automatic token renewal, DM/group metadata, phone routing, and shared-pool line behavior. Public ingress is not required for this SDK path.
- [Photon CLI authentication](https://photon.codes/docs/cli/authentication): browser device authorization exists for the Photon CLI; its CLI stores credentials in local files. Otto avoids that storage path and uses Keychain.
- [Hermes device-auth implementation](https://github.com/NousResearch/hermes-agent/blob/main/plugins/platforms/photon/auth.py): describes hosted client allowlisting and uses `photon-cli`. This is evidence about the reference implementation, not permission for Otto to impersonate that client.
- [Photon pricing](https://photon.codes/pricing): advertises a free individual tier with shared numbers. Its marketing message limits differ from the technical quota page. No quota or permanent-free promise is embedded in Otto.
- [Photon terms](https://app.photon.codes/terms-of-service): owner-managed accounts and restrictions on credential sharing/resale. No representation is made that Photon has approved Otto distribution or unlimited independently owned installations.
- [Published Spectrum package](https://www.npmjs.com/package/spectrum-ts): resolved and pinned **12.8.0** with a lockfile. Installed `.d.ts` definitions verified `direction`, `sender.id`, `space.id`, `imessage(space).type/phone`, `imessage(app).space.get`, `app.stop`, the outbound message ID, and telemetry configuration.

Packaging scripts include `Otto_OttoServices.bundle`; the adapter resolves its packaged resource location without relying on an absolute build-machine path.

The bundled adapter is a real SDK adapter, not a mock response generator. Its live network behavior still requires a user-owned authorized project and assigned phone. Automated tests inject a simulated provider; native preview explicitly says **SIMULATED PROVIDER** and uses in-memory secrets.

## Verification commands

```sh
node --test PhotonBridge/bridge.test.mjs
scripts/otto-swift build --product Otto -j 4
OTTO_MESSAGING_TESTS_ONLY=1 scripts/otto-swift test -j 2 --filter 'Messaging|messagingTextVerticalSlice'
```

Use `--messaging-preview` in a debug build to inspect the actual SwiftUI Settings view against an isolated fixture. It does not start the application runtime, use Keychain, or connect to Photon. Do not use that preview as evidence of live delivery.

## Live acceptance remaining

With an owner-approved, already configured Photon account: install/connect, verify the assigned destination and exact SDK sender shape on a real inbound event, pair, send one text, inspect the coordinator's response on the phone, exercise provider interruption and reconnect, and verify disconnect. Also confirm provider replay behavior across an offline period; local durable acceptance does not guarantee Photon replays events the host never received. A first-party device authorization client and remote project-secret revocation API remain unverified extensions, not fabricated endpoints.

## Review corrections — 10 September 2026

Interrupted sessions retain their desktop-review gate and checkpoint. Messaging sends a separate review notice and holds queued requests while review or checkpoint state remains unresolved. Dispatch checks the gate again immediately before entering the runtime.

Replies are resolved in the unique persisted session containing the request ID and stop at the next user message. A later desktop answer cannot become an earlier phone response. Missing or ambiguous attribution yields a review notice and an uncertain job, never a borrowed answer.

The debug-only flag `--messaging-preview-cleanup-failure` (used together with `--messaging-preview`) injects one in-memory secret-deletion failure for native testing of Retry disconnect. It never affects the real Keychain implementation.

Shared-pool SDK routing: Spectrum reports space.phone as `shared`, not the assigned physical number. Pairing accepts that authenticated project route while requiring the configured account and exact sender; it pins the provider route and conversation for subsequent messages. The physical destination stays visible for the user to text.
