# Personal Boat cloud host

This is a personal-account cloud execution option, available from Home → Cloud and Settings → Cloud. It uses Boat's API-managed Codex/Claude harness, not Otto's local agent supervisor. Cloud conversations remain separate from saved Otto bot channels. Local files, Project Brain, browser cookies, permissions and tool RPC are not automatically transferred.

## Setup

1. Sign in to Boat and configure Codex or Claude on its Agents dashboard.
2. Create a Boat API key in Boat's dashboard. Enter it into Otto's secure Cloud field, never a chat. The credential uses explicit macOS Keychain storage even in Dev.
3. Leave trial-only mode on to reject create/resume when Boat doesn't report an active trial. The trial is finite; this is not a promise of free hosting indefinitely.
4. If you want the personal machine to receive your configured Boat repositories/provider credentials, explicitly enable **Use my configured Boat environment**. Otherwise create uses `noEnv: true` and receives no account environment. An isolated machine needs its own agent configuration before it can run useful work.
5. Create a small machine. Refresh until ready, choose the machine, and send a task. Provider/model defaults are managed in Boat; Otto does not hardcode a changing model catalog. Fast mode is disabled.
6. Keep Otto closed while work continues remotely, then reopen Cloud, reconnect using the saved Keychain key, select the machine, and refresh. Stop the machine when done.

Every create/resume requests a one-hour auto-stop. This is a bounded trial/personal prototype, not unlimited always-on execution. Stop preserves snapshots but ends hand-run processes. Resuming does not replay a prompt automatically. Boat conversation history is continued by its returned conversation ID.

## Boundaries

- Personal billing wallet explicitly selected with `X-Boat-Org: personal`. Otto never adds a payment method, buys credits, or enables auto-refill.
- Trial-only is a start gate, not a total spending cap. Turning it off can incur charges on the user's Boat account. AI charges are controlled by that user's provider/Boat configuration.
- Fixed HTTPS origin, ephemeral URLSession, redirects rejected, no automatic mutation retry. Remote error bodies and desktop access URLs are not logged or saved.
- Machine and conversation identifiers, uncertain-send markers, and pending create intent are saved locally. Input/output bodies are not persisted by this integration. Boat stores its own conversation history under its own policy.
- Pending creation records its original idempotency key and exact request options before network submission. Lost-response retries retain both across relaunch. Retry stops at 23 hours, inside Boat's documented 24-hour key retention; expired attempts require checking Boat before any new provisioning.
- The prompt endpoint has no documented idempotency guarantee. Network errors and ambiguous responses preserve an uncertain marker and block another send until the user checks Boat. Definitive 4xx rejection clears that marker; no prompt is automatically replayed.
- Events are requested with a conversation filter and displayed only for the selected machine. Typed decoding ignores unknown fields, desktop URLs and tool payloads.
- Removing the saved Keychain connection does not stop or delete cloud machines. Stop is explicit; permanent deletion isn't exposed.

## Later hosted service / Stripe boundary

This personal client must not be used with an Otto platform-wide service key in a shipped client. A multiuser service needs a server-side credential broker, authenticated tenant ownership, isolated `noEnv` machines, scoped credential setup, quotas/usage ledger, webhook/reconnect delivery, and entitlement checks before any billable operation. Stripe can implement the entitlement/payment interface later, but it does not supply these boundaries by itself.

No account was created, terms accepted, credentials entered, or real cloud machine provisioned during local implementation. Contract tests exercise API requests and failure behavior through an injected transport. Live acceptance needs the user's secure Boat setup.

## API sources (reviewed 7 October 2026)

- https://docs.boat.dev/api/v1
- https://docs.boat.dev/platform-guide
- https://docs.boat.dev/pricing
- https://docs.boat.dev/api/reference/sandboxes/create-sandbox
- https://docs.boat.dev/api/reference/sandboxes/resume-sandbox
- https://docs.boat.dev/api/reference/agent/prompt-sandbox-agent
- https://docs.boat.dev/api/reference/agent/list-sandbox-events
