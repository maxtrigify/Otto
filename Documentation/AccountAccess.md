# Private website accounts

Otto Settings → Websites now connects the account-policy broker to an isolated website session.
Ask your agent to sign into a website. It requests native approval for access by that bot, opens **Sign in privately** at the login URL, and waits for completion. Settings also supports manual account management.
Enter the website password and any verification code directly into the private website window.
After checking the resulting account, choose **I'm signed in — allow bot access**. Otto retains
website cookies, not the submitted password. A bot can request sign-in, but cannot approve it.

## Execution and approval

`browser.account` is the account-session tool: `list`, `request_login`, `open`, `inspect`, `type`
and `click`. Account storage is never attached to ordinary canvas browser nodes. There is no
account JavaScript, screenshot, cookie export or credential retrieval tool. The host derives the
bot profile and run from its authenticated tool context; callers cannot supply another bot ID.
Each operation checks the owner/workspace/bot grant, exact origin and session approval. Checks
run again after suspension before releasing page output. Each click requests a one-shot approval on its originating surface, showing the origin, account and inspected button label. Element revisions are
single-use and changed targets fail closed. Password and one-time-code pages pause bot access.

Each account uses a distinct persistent `WKWebsiteDataStore` UUID. The human login window has
window sharing disabled and is excluded from Otto's window recorder. No agent renderer,
console observer or debug bridge is registered for it. Grant changes close local renderers and
invalidate input requests. Disconnect removes policy first and clears local website data.
Other controllers recheck current policy before use. Disconnect does not revoke sessions on
other devices or log out the website globally.

Policy lives in the dedicated `io.openotto.account-access` Keychain service. A per-user advisory
process lock serializes record transactions between current Otto builds. Corrupt records,
Keychain failures and overlapping transactions fail closed. Test storage injection is package
scoped; production services use the shared Keychain broker.

## Paired mobile private input

In the paired native mobile app, open **Secure Sign-in**. This uses a separate authenticated
`POST /v1/secure-login` endpoint, never the generic RPC, transcript, attachment, event journal or
message-retry path. The paired device needs `secure-login:control` (mapped to computer control);
legacy bearer-only connections cannot submit. Older pairings may need pairing again. Requests
expire after five minutes and bind to the first authenticated device that opens the form. Each
field submission consumes its page revision. Fill in the form and tap the website
button once; all filled fields travel in one revision-bound private submission and the phone clears them. Input is redacted
in descriptions/reflection and errors return fixed messages. Replays, another device, expired
requests and cancelled requests are rejected. Revoked devices fail transport authentication.

The client uses an ephemeral session with no automatic redirect, cache or application retry,
and requires HTTPS except loopback development fixtures. The managed commercial relay is
**not** a secure-input transport; it rejects this feature. Use a direct paired HTTPS connection
or the separate private phone-link service below. iMessage carries private links and subsequent
results, never a password or verification code. Completing sign-in returns the pending tool call and the agent continues its original task. Cancelled, expired or interrupted tool calls are not replayed automatically.

## Private links from Messages

When the packaged app has `OttoPrivatePhoneURL` configured, website requests from a paired
messaging job use the separate private-input Worker. The Mac creates its own Keychain identity;
users do not configure hosting, accounts or network ports. Otto sends a five-minute link directly
to the owning conversation without inserting it into agent or durable Otto messaging history.
The phone page asks for website access, accepts private form input and exact website-click
approvals, and returns control to the same agent task. No Mac visit is required for these steps.
The Mac must remain online. Generic non-website permissions still use existing Otto controls.

An explicit Remember checkbox saves supported username/password forms in a separate
Keychain-only vault after human confirmation. It never saves verification codes. Reuse checks
the original form signature, current bot grant and previously confirmed distinct success URL.
Changed forms, MFA or ambiguous success require private sign-in again. Disconnect revokes
access before deleting credentials and cookies; failed cleanup remains retryable.

The static page and relay are first-party trusted infrastructure. The relay handles encrypted
payloads and short-lived routing metadata; the host checks capability, peer key, request scope,
expiry and replay before execution. The link is a bearer capability until claimed. Details,
deployment instructions and remaining public acceptance gates are in `PrivateSignIn/README.md`.
The packaged endpoint is https://muse-private-sign-in.muse-private.workers.dev. Public
relay and Swift connector checks passed; end-user acceptance evidence is tracked separately.

## Supported boundary

This slice supports same-origin HTTPS username/password and verification-code workflows.
Cross-origin identity-provider redirects, popup authentication and 1Password integration are
not implemented. Such sites fail closed; they are not evidence of a completed supported login.
Account pages are trusted website content: normal authenticated page text is visible to the
approved bot. The executor does not promise to recognize every custom credential widget.

Keychain and private WebKit storage are not an OS sandbox against unrestricted same-user shell,
computer-use tools, injected app code or memory inspection. Swift strings are not guaranteed
zeroized. Website scripts necessarily receive credentials submitted to their own forms. Native
secure input avoids the model/tool transcript; it does not make an untrusted website safe.

## Verification

`WebsiteAccountTests` exercise real WebKit form submission against a synthetic local fixture:
password, verification code, session reuse in a recreated controller, selected/future-bot access,
revocation, disconnect, native click detail, replay, cancellation, expiry and secret redaction.
`OttoHostTransportTests` exercise paired secure input, legacy/wrong-scope rejection, fixed errors
and absence of event-journal writes. Existing broker/mobile/runtime tests remain part of the run.
No tests use a user's private website credentials. Native UI and live acceptance evidence is
recorded separately with the integration handoff.
