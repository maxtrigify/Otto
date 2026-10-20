# Provider-native marketplace

Otto's **Marketplace** opens the provider's existing app connection flow. It is available in the Chat sidebar, agent details and Settings → Marketplace. It uses the Grok Bot Connect Apps layout as a visual reference: search, category pills, two-column app rows, and Your apps.

## Connection sources and accurate status

- Codex: read-only `initialize → account/read → app/list` pagination followed by optional `app/installed`. No thread, inference turn, install mutation or credential export. `isAccessible=false` is normal for an unconnected directory entry: a valid provider `installUrl` still offers Connect with Codex. `callable=true` is displayed as Enabled, not proof of Gmail OAuth authentication. The current CLI must support `app/list`; missing/failed discovery shows a retryable notice, never a made-up catalogue.
- Claude Code account connectors: a small published starting set (Gmail, Google Calendar, Microsoft 365) opens `https://claude.ai/customize/connectors`. The user chooses the app and completes sign-in there. This is a curated starting set, not live per-account eligibility. Browse all Claude connections opens the full official directory. Subscription authentication and provider plan/organisation determine availability. No undocumented Anthropic endpoints are called.
- Claude Code, Cursor, Grok Build and Kimi Code: public official plugin catalogue feeds load concurrently, without credentials. These packages can contain skills/hooks as well as connections; entries are labelled Plugin rather than presented as connected accounts. Cursor's repository is a subset of its marketplace. Grok Build is not Grok Bot's app directory.
- OpenCode: a separate **Community MCP** source reads the first 500 latest-version registry records (five pages), showing Streamable HTTP servers with fixed HTTPS URLs and no required header configuration. Registry presence does not prove OAuth support or free access. The source link opens the complete registry.
- Existing local declarations remain Configured for this Mac. Cursor/OpenCode remote declarations can start their native MCP sign-in commands. Named-account local inventories are omitted rather than borrowing the Mac's configuration.
- Hermes is excluded and keeps its own connections.

Opening setup never marks a connection successful. Return to Otto and refresh; Codex's live runtime state is fetched again. Refresh also runs when a setup handoff returns to the active scene. Browser login may differ from the selected CLI account; the details panel explicitly asks users to check it. No browser session tokens are imported. Native provider tool calls retain that provider's own permissions and approval path; they do not pass through Otto's shared-Gmail registry.

## Identity and security

The marketplace account picker is explicit: This Mac's login, or a named Otto provider account. Chat initially uses its selected agent's effective account. Named Codex API-key accounts cannot borrow subscription apps. Deleted accounts fail closed. Account changes invalidate the catalogue, and request generations reject stale in-flight responses. Catalogues are not written to disk by Otto.

Provider install URLs must be HTTPS, exactly `chatgpt.com`, have no credentials or custom port, and target `/apps/` or `/plugins/`. Text and catalogue pages are bounded (10,000 entries, 100 pages, 32 MB across the stream, 60 seconds for app discovery); duplicate IDs and malformed entries are filtered. Probes time out and reap their own child processes. App catalogue discovery opts in to the documented experimental API capability for CLI compatibility, and forces a refresh only on the first page. Provider environments and catalogue payloads are not logged.

## Existing shared Gmail

Advanced opens the previously implemented Otto-owned shared Gmail connection. Existing credentials and access controls remain intact. It is an optional direct connection requiring the installation's own Google OAuth application, separate from native provider connections. This marketplace does not add Composio, subscription charges, a platform API key or a new Google registration requirement.

## Limits and acceptance

This is a native app connection marketplace, not universal plugin installation. Skills/hooks/package install and additional official MCP adapters are future work. Do not claim every provider exposes a catalogue API, or that native Claude/Codex Gmail is shared across competing providers.

Reference docs:
- https://learn.chatgpt.com/docs/app-server (app/list, app/installed)
- https://github.com/openai/codex/blob/main/codex-rs/connectors/src/lib.rs (directory accessibility semantics)
- https://code.claude.com/docs/en/mcp#use-mcp-servers-from-claudeai

Validation includes mocked native RPC handshakes, account isolation, stale-result rejection, URL validation, status and filtering tests, and a native UI preview. Real OAuth consent and native connector calls require account-specific acceptance and are not implied by catalogue discovery.

Validated on 2026-10-08: 48 focused checks passed, including live native Codex discovery of 5,003 catalogue entries and 11 enabled apps, without starting inference or authorising a new connection. Native preview exercised search, provider/category filters, Your apps (including category reset), Claude setup details, and disabled setup for locally configured tools. The reference Grok Bot panel was visually inspected; its controls were unresponsive while it reported an unreachable computer.

## Public catalogues and setup actions

Public feed URLs are fixed in `PublicPluginCatalog`: Anthropic's `.claude-plugin/marketplace.json`, Cursor's `.cursor-plugin/marketplace.json`, xAI's `.grok-plugin/marketplace.json`, and Kimi's documented `code.kimi.com/kimi-code/plugins/marketplace.json`. Each response is bounded to 4 MB and 10,000 entries, uses an ephemeral credential/cookie-free URLSession with 15/20-second timeouts, rejects unexpected redirects (the exact Kimi first-party CDN feed redirect is allowed), validates identifiers and deduplicates listings. Failed sources show retry notices while other catalogues remain available. Account/request generations reject stale responses. Public listings never imply account entitlement.

- **Install with Claude Code** registers the official marketplace and invokes `claude plugin install <id>@claude-plugins-official --scope user`. Command-source packages cannot auto-install.
- **Install with Grok** uses the official source and preserves full commit SHA pins for remote repositories. Local vendored sources use the official repository subdirectory. Trust is never bypassed with `--trust`.
- **Cursor** hands full plugin setup to its official marketplace. When a plugin's published `mcp.json` contains a fixed remote HTTPS server without headers/commands, details also offers a documented `cursor://.../mcp/install` link. Only the URL transport is forwarded; native Cursor reviews installation. Requires this Mac's account. Missing/complex configurations keep the marketplace handoff.
- **Kimi** uses its documented interactive plugin manager: details shows a copyable `/plugins install <validated-source>` command and links official setup instructions. No model prompt is used to simulate a slash command.
- **Connect with OpenCode** adds one hashed server identity to this Mac's `~/.config/opencode/opencode.json`, preserving existing settings, then starts `opencode mcp auth`. Existing JSONC, symlinked files, collisions, malformed/unreadable configuration and detected concurrent edits fail closed for manual setup. A server registered before unsuccessful auth remains configured; the UI states this and never claims connected state.
- Existing **Cursor/OpenCode** remote connections offer **Sign in** using their documented `mcp login`/`mcp auth` commands in the current workspace.

Native mutations use this Mac's login only. Named-account actions are disabled because some account plugin folders share files with the machine's configuration. Browser handoffs remain explicit about checking the browser account. Jobs pass fixed argument arrays through `posix_spawn` rather than a shell; no inference is started, no catalogue command is executed, and CLI stdout/stderr are discarded rather than copied into chat. Provider/account and Otto environment prefixes are scrubbed. Each job owns a process group, including git children, and reaps it with bounded timeouts. Native success is reported as installation/setup completion, not an OAuth/account eligibility guarantee.

This extension was developed in an isolated worktree and must be visually checked through a separate preview. The running Otto Dev app is not replaced or restarted for this task. Live user account authorization and real third-party package installations are outside automated acceptance; fixtures cover commands, timeouts, catalogue parsing, account isolation, configuration preservation and direct-link contents.

### Extension acceptance — 8 October 2026

29 focused checks passed (18 runtime/catalogue checks plus 11 marketplace/account checks). Live Swift catalogue reads returned Claude315, Cursor100, Grok31, Kimi6 and336 community remote MCP listings from the first500 registry records. The Kimi feed's exact first-party CDN redirect is allowlisted and regression-tested. Full debug app compilation, strict formatting of changed Swift files and diff checks passed. Test log: `/tmp/muse-public-marketplace-acceptance.log`.

Native UI acceptance used the separately signed `Otto Catalogues Preview.app`: Kimi catalogue and copyable setup command; Cursor Gmail's published Google remote MCP URL and Connect link; Grok Vercel Install details; named-account installation disabled; OpenCode community provenance and named-account connection guard. No real third-party installation, native OAuth consent or mail action was performed. The preview was closed and its supervised terminal completed with exit0.

The change remains committed on `codex/marketplace-public-catalogues`, based on current main `e0650ad`; it has not been integrated or installed into the running Otto Dev. Its installed Info.plist has `OttoDevelopmentAutoReload=true` and watches the integration checkout. Main-source changes would therefore trigger rebuild/relaunch through `DevelopmentAutoReloader.swift`. Integration is deliberately staged until a reload is acceptable, preserving the user's ongoing Otto Dev work. No sources in main or installed Otto Dev files were changed by this extension task.
