# Browser confirmation stalls

## Reproduction from the session trace

On 20 October 2026, a Cloudflare Save click requested at 11:48 UK time received no response for 1,800 seconds. The provider timed it out at 12:18. Two following browser calls returned at 12:48, consistent with the bridge's 3,600-second approval socket timeout. The session then resumed useful work.

The MCP executable read one line, synchronously handled it, and only then read the next. Late-bound browser confirmation called `agent.request_permission` with the same one-hour socket deadline as explicit human questions. The supervisor parked the approval continuation with no expiry. A provider timeout neither expired that card nor freed the serial bridge promptly.

## Fix

- Browser-click approvals expire in the supervisor after 60 seconds. Expiry removes the exact request, records a transcript notice, advances the next approval if any, and returns a structured denial. A stale request ID/nonce cannot approve anything afterward.
- The bridge gives the app 65 seconds to return this result and preserves the reason in the MCP tool error. It only replays a click after an affirmative approval and a cancellation check.
- The stdin reader dispatches requests to a bounded worker queue and serializes complete response lines. Browser requests on the same node retain arrival order; requests for other nodes and non-browser tools can proceed during an approval wait.
- MCP cancellation skips queued work and prevents a pending confirmation from replaying an abandoned action. Cancellation cannot undo an action already sent. An active cancelled approval card may remain until its server-side 60-second expiry or a user decision.
- JSON-RPC notifications receive no response.

Explicit provider permission requests, private account sign-in, and `agent.ask_user` retain their existing human-wait policy. This change does not automatically approve any action.

## Validation

Focused tests cover request scheduling and queued cancellation, server-side expiry, stale approval rejection, queued expiry preserving another request, timer cancellation after approval, and a real control-socket/MCP round trip proving expired or cancelled approval never executes the browser action. Existing permission and protocol tests cover successful approval and private sign-in waits.

The installed app and already-running MCP helpers require a rebuilt app and a new helper process to use the fix; source integration alone cannot change an existing helper's behavior.

Validation completed: app build succeeded; all 27 focused tests passed using `scripts/otto-swift test --filter 'AgentPermissionTests|PermissionPromptToolTests|MCPRequestDispatcherTests|ProtocolAdapterTests' --no-parallel --jobs 4`. Strict formatting and diff checks passed. `Package.resolved` is unchanged. Existing warnings in unrelated automation code remain.
