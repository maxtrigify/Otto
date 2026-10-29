# Shared app connections

Otto owns the Gmail account connection independently from provider subscription logins. One account is automatically available through the existing Otto MCP bridge to Claude Code, Codex, Cursor, Grok, Kimi and OpenCode. Hermes, shell, and direct API runtimes are excluded from this rollout. No provider-native OAuth tokens are imported.

## User experience

Open **Settings → Connectors → Gmail** for the shared Gmail connection (the same panel also opens from **Marketplace → Advanced**). The default [provider-native marketplace](ProviderMarketplace.md) uses existing provider sign-in flows and does not require this Google registration. Connect Gmail through Google's sign-in screen. Read access is the default; the optional draft/send switch requests the additional scopes during connection. Account cards support reconnect, disconnect, multiple accounts, and pausing sharing. If several accounts are connected, agents must select an account returned by `apps.accounts`.

Each connector lists the Otto bots allowed to use it. A bot reaches Gmail, Google Calendar or Email (SMTP) only when it is ticked on that connector's page; ad-hoc sessions and archived bots are refused even while their process runs.

New tool discovery takes effect on the next provider launch/turn. A provider that caches its current tool list may need its session relaunched. Calls always check the current connection even when a provider retains an old schema. Changing the provider of a supported agent reuses the account.

## Google application provisioning

This code does not ship a fabricated OAuth client. An Otto-owned **Desktop app** OAuth client must be registered in Google Cloud with the Gmail API enabled, the appropriate consent branding, and authorised scopes. During testing, add permitted Google accounts as test users. Google verification and restricted-scope requirements apply before public rollout.

Set the public `OTTO_GOOGLE_CLIENT_ID` at packaging time. `scripts/configure-google-app-client` inserts it into the app's Info.plist as `OttoGoogleClientID` for both development and distribution builds. Do not put user tokens or client secrets in the plist, project files, or chat. For a local installation, **Connect apps → Advanced** accepts the client ID and, if Google requires one for that registration, a client secret through a SecureField. The client ID is stored in Application Support; the optional secret is stored in the app-connections Keychain service. Shipping users receive the configured app and only complete Google sign-in.

Google's installed-app flow requires a system browser; embedded WKWebView authentication is rejected by Google. The implementation uses a transient IPv4 loopback listener bound to 127.0.0.1 on an ephemeral port, random state, S256 PKCE, a three-minute timeout, and cancellation. Invalid/duplicate callback parameters do not consume the transaction. No user password or MFA input passes through an agent.

## Credentials and execution

Refresh/access tokens remain in `KeychainSecretStore(service: "io.openotto.app-connections")`, including debug builds. The default development file secret store is deliberately not used for these accounts. Workspace `.otto/app-connections.json` stores account metadata and a random credential reference only. Credential keys include the standardised workspace path hash, account ID, and credential generation. Refresh tokens are never supplied in provider subprocess environments, tool schemas, or outputs.

Every tool discovery and call resolves the authenticated source node to its live supervisor provider and persisted agent definition. Unsupported providers are denied. Read-only agents cannot use draft/send. Tools are filtered by Google scopes and current shared/reconnect state. Disconnect removes local authority before waiting for token revocation. A failed Google revocation is reported separately; locally disconnected accounts remain unusable. A revoked or replaced generation cannot restore credentials through a late refresh.

A Gmail send requires the existing exact-call Otto confirmation path and declares `sendOrPublish` to the external-effect coordinator. Send requests are not automatically retried, because a network failure can leave delivery uncertain. Gmail search/read/thread do not alter read state. Private content returned by those tools enters the selected model's context.

Available tools: `apps.accounts`, `gmail.search`, `gmail.read`, `gmail.thread`, `gmail.draft`, `gmail.send`.

**Google Calendar** reuses the Google account. **Settings → Connectors → Google Calendar → Grant calendar access** reconnects it with `calendar.readonly` and `calendar.events`. Tools: `calendar.events` lists the primary calendar between two RFC 3339 times (start before end, at most 50, returned as compact id/summary/start/end/location/status/link records), and `calendar.create_event` creates an event after Otto confirmation. Events never invite attendees. Message bodies decode multipart plain text (or HTML fallback), preserve attachment metadata, and are bounded. Search is limited to 20 results per page; thread responses are limited to 20 messages and report truncation. Attachment downloads, label mutations, third-party app connectors, and provider-native plugin installation are not part of this Gmail implementation.

## Verification

Use `scripts/otto-swift test --filter 'AppConnectionsTests|HarnessPluginCatalogTests|ControlServerTests|MCPBridgeTests|ProviderAdapterTests|ToolRegistryTests'`. Tests use generated dummy credentials and an in-memory vault; they do not authenticate to Google, consume model subscriptions, send mail, or modify real provider logins.

The native production panel can be opened in an isolated debug workspace with `Otto --apps-preview --workspace /path/to/disposable/workspace`. This preview is unconnected, not a simulated successful Google login.

The remaining live acceptance check requires the registered OAuth application and human Google consent: connect a real account, read a known message through the supported CLIs, switch providers, then verify reconnect and removal of access. Public-release OAuth approval is separate from compilation or unit-test success.

Official reference: https://developers.google.com/identity/protocols/oauth2/native-app
