# Provider adapters

Otto discovers provider executables from the app process `PATH`, records their reported versions, and builds launch-scoped process specifications. It does not modify a user's global provider configuration.

## Claude Code

- Detection: `claude --version`
- Interactive launch: `claude` with the selected permission mode
- One-shot launch: `claude --print --output-format text <prompt>`
- Read-only mapping: `--permission-mode plan`
- Workspace-safe mapping: `--permission-mode default`
- Unrestricted mapping: `--permission-mode bypassPermissions`; this must require explicit product confirmation

## Codex

- Detection: `codex --version`
- Interactive launch: `codex`
- One-shot launch: `codex exec --json --skip-git-repo-check <prompt>`; Otto applies the permission
  sandbox independently, so a legitimate non-Git workspace is not rejected by Codex's repository
  trust preflight
- Resumed launches retain `--skip-git-repo-check` and apply the chosen permission through Codex's
  supported `sandbox_mode` launch configuration
- Read-only mapping: `--sandbox read-only`
- Workspace-safe mapping: `--sandbox workspace-write`
- Unrestricted mapping: `--sandbox danger-full-access`; this must require explicit product confirmation

## Hermes

- The connection preference defaults to Local and is shared by launches from the canvas, command
  palette, tools, and voice.
- Otto deliberately does not pass its generic agent `model` or `effort` fields to Hermes. Hermes
  always uses the model/provider pairing configured in the selected Hermes profile, preventing a
  Claude model saved on a reused Otto node from being sent through a Codex account transport.
- Local detection: `hermes --version`; interactive launches use the native Hermes TUI and prompted
  runs use `hermes -z` through the bundled `otto-hermes-bridge` so the final response and resumable
  session ID enter Otto as structured provider events.
- Remote detection and execution: `otto-hermes-bridge` connects to the configured `hermes serve`
  `/api/ws` JSON-RPC endpoint, validates it with `session.list`, creates or resumes a session, and
  submits prompts with `prompt.submit`.
- Otto does not choose or repair Hermes' provider/model pairing. Unless an explicit model is passed
  to the bridge, `session.create` omits both fields and Hermes uses its own configured defaults.
- Remote connections may name a Hermes profile. Otto forwards only that profile name; Hermes then
  supplies the profile's provider, model, memory, skills, and credentials. This avoids a
  multiplexed gateway labelling a session with its active profile while building it from the
  unscoped default profile (for example `claude-opus-4-6` through a Codex/ChatGPT account).
- Remote Hermes browser work stays on the Otto canvas. Because a remote gateway cannot spawn the
  app's local stdio `otto-mcp`, the adapter teaches Hermes a private browser-call envelope carried
  over Hermes' existing authenticated `clarify.request`/`clarify.respond` channel. The bridge
  consumes those marker-bearing requests without rendering them as user questions, accepts only
  `node.list` and the allowlisted `browser.*` operations, and invokes the normal local MCP/control
  stack with the launch's node- and canvas-scoped token. Ordinary clarification questions still
  render normally. The bridge opens no listening port and never sends the Otto control token to
  the remote host.
- Browser authentication remains a human handoff: Hermes leaves the login/MFA/CAPTCHA page open in
  the canvas, the user completes it directly in the Otto browser, and Hermes re-inspects on the
  next turn. Passwords and authentication answers never travel through Hermes chat or the tunnel.
- Local Hermes one-shot/TUI launches do not use this compatibility tunnel: they still need native
  Hermes MCP registration before they can receive Otto tools. The remote path is the supported
  configuration for Hermes-driven canvas browsing in this release.
- The remote session token is stored only in Keychain and is read by the bridge; it is never placed
  in process arguments, preferences, or diagnostic output.
- Remote working directories are paths on the Hermes host. Otto therefore disables local isolated
  worktrees in remote mode.
- Remote composer attachments cross the gateway as bytes using Hermes Desktop's existing
  `image.attach_bytes` protocol. Generated `file://` artifacts are fetched through the authenticated
  managed-files endpoint, saved under the local workspace's `.otto/hermes-downloads`, and rewritten
  to local links before Otto renders the final response. The Hermes Desktop app is not required.
- Workspace-safe mapping uses Hermes' normal approval flow. Unrestricted mapping passes `--yolo`
  locally and relies on the remote profile's approval policy remotely. Hermes does not currently
  expose a strict provider-wide read-only mode, so Otto rejects that combination instead of
  presenting it as sandboxed.

## Kimi

Kimi Code CLI (the TypeScript `kimi`, successor to the Python `kimi-cli`).

- Detection: `kimi --version`. The official installer writes the binary to `~/.kimi-code/bin` and
  appends that directory to the shell rc file, which a LaunchServices-started app never sources, so
  the adapter probes that path explicitly alongside `PATH`.
- Interactive launch: `kimi` (native TUI)
- One-shot launch: `kimi --output-format stream-json --prompt <prompt>`. There is no `--print`
  flag; `--prompt` *is* Kimi's non-interactive mode, and `--output-format` is only valid with it.
- Permission mapping is split by launch shape, because Kimi rejects `--plan`, `--auto`, and
  `--yolo` alongside `--prompt` at startup — a non-interactive run always uses its `auto` policy:
  - Interactive: read-only maps to `--plan`, workspace-safe uses Kimi's normal approval flow, and
    unrestricted passes `--yolo`; this must require explicit product confirmation.
  - Prompted (chat) runs pass no permission flag. Otto therefore refuses read-only for prompted
    Kimi runs instead of presenting auto-approval as a sandbox, and workspace-safe chat runs do
    auto-approve tool calls. Kimi has no OS-level sandbox at all, so this is materially weaker
    than Codex's `--sandbox` and must not be described as equivalent.
- Otto passes no model from its own catalogue: `--model` accepts only aliases declared in the
  user's `~/.kimi-code/config.toml`, so model choice belongs to the CLI (`/model`) and
  `agent.set_model` rejects Kimi nodes. Kimi exposes no reasoning-effort flag.
- Print mode emits OpenAI-shaped chat messages (`{"role":"assistant",…}` with `tool_calls`, then
  `{"role":"tool",…}` results) rather than a typed event stream. An assistant message with no tool
  calls is what ends the agent loop, so Otto treats it as the turn's result.
- Kimi announces no session id in print mode, so continuations use `--continue`, which reopens the
  most recent session for the working directory. The parser reports
  `KimiAdapter.continuationSessionToken` as the run's session id and the adapter translates it back
  into that flag; a real id is preferred if a future build emits one. Consequence: two Kimi nodes
  sharing one working directory would continue the same session, so parallel Kimi work wants
  isolated worktrees. For the same reason `ProviderSessionStore` cannot yet harvest a Kimi TUI
  stint into the chat transcript, and Otto orchestration v1 still admits only Claude Code and Codex.
- Kimi has no MCP launch flag: servers come from `mcp.json`, user-level under `~/.kimi-code` or
  project-level in the working directory. The adapter writes only the project-level
  `<workspace>/.kimi-code/mcp.json`, merging its own `otto` entry into any existing file (and removing a `muse` entry only when Muse
  itself wrote it before the rename), so the
  user's global configuration is never modified. The entry carries `toolTimeoutMs` of one hour
  because `agent.ask_user` and permission approvals block on a human answer.
- That entry deliberately carries no `env`. The supervisor already injects the scoped `OTTO_*`
  control values into the Kimi process, and a stdio MCP child is expected to inherit them, which
  keeps the file identical for every Kimi node so two nodes in one directory cannot overwrite each
  other's token. Unlike Claude Code and Codex — whose CLIs are known to scrub the environment for
  MCP children — this inheritance is an assumption about Kimi and is the first thing to verify
  against a live install; if it does not hold, the bridge fails to authenticate and Kimi keeps
  working as a coding agent without canvas tools.
- Kimi has no `--append-system-prompt` equivalent, so the canvas guidance and the memory bootstrap
  are embedded ahead of the first task prompt the way Codex and Hermes receive theirs;
  continuations skip both because they are already in the resumed session.
- Kimi's blocking TUI prompts are answered from chat rather than the terminal. Its folder-trust
  question is auto-confirmed like Claude's, because declining it disables the project MCP servers
  the adapter just wrote. Its `/login` platform picker is lifted out of the repaint by
  `InteractiveMenuParser` and surfaced as an `AgentChoicePrompt`, so the options render as chat
  buttons; picking one is delivered to the harness as cursor keys plus Enter, since a TUI menu
  reads arrow keys and ignores typed text. An answer matching no row is left alone, so a typed
  reply still falls through to the terminal.

## Cursor

Cursor CLI (`cursor-agent`), the editor's coding agent without the editor.

- Detection: `cursor-agent --version`. The installer writes to `~/.local/bin`, probed directly for
  the same LaunchServices reason as Kimi and OpenCode.
- Interactive launch: `cursor-agent` (native TUI)
- One-shot launch: `cursor-agent --print --output-format stream-json <prompt>`
- **Versions are calendar builds** (`2026.08.04-aaa8809`), not semver. `ProviderCompatibilityPolicy`
  branches before its shared parser, which would otherwise read that as 2026.8.4 and mark every
  install untested. The CLI self-updates and keeps its flag surface stable, so a well-formed stamp
  is treated as supported.
- Two prompts a headless run cannot paint are pre-answered on every launch: `--trust` (Otto owns
  the directory it launches in — the flag Kimi lacks, which is why Kimi needed a TUI trust detector
  instead) and `--approve-mcps`.
- Permission mapping: read-only is `--mode=plan`, workspace-safe uses Cursor's own approval flow,
  and bypass is `--force`. Unlike Kimi, read-only works for headless runs too.
- Session resume is by real chat id: `system`/`init` announces `session_id`, replayed as
  `--resume <id>`. `create-chat` can mint one up front if a future caller needs it.
- Models are account-specific and span Composer, GPT, Claude, Grok, and Kimi tiers, so
  `CursorAdapter.availableModels()` reads `cursor-agent models` at runtime and parses
  `<id> - <display name>`; `AgentModelCatalog` holds only a two-entry fallback. This is the first
  provider whose catalog is discovered rather than hardcoded.
- MCP: no launch flag. Servers come from `~/.cursor/mcp.json` or the workspace's `.cursor/mcp.json`;
  Otto writes only the project-level file and only its own `otto` entry (a Muse-written `muse` entry is removed), with no `env` — scoped
  credentials are inherited from the process, so parallel nodes cannot leak each other's token.
- The event stream resembles Claude's but differs in three ways the parser has to handle: the
  session id arrives on `system`/`init` rather than with the result, reasoning streams as
  `thinking` deltas closed by a `completed` record, and tool calls are typed by key
  (`shellToolCall`, `readToolCall`, `editToolCall`) instead of carrying a `name`. An edit call
  carries the entire new file in `streamContent`, so tool details name fields explicitly rather
  than falling back to the longest string.
- No `--append-system-prompt`, so canvas guidance and the memory bootstrap ride ahead of the task.
- Sessions are stored under `~/.cursor/chats`, not as readable transcripts Otto can attribute, so
  `ProviderSessionStore` harvests nothing and the live stream is the transcript source.

## OpenCode

OpenCode (<https://opencode.ai>), the `opencode` CLI.

- Detection: `opencode --version`. The installer writes the binary to `~/.opencode/bin` and appends
  that directory to the shell rc file, which a LaunchServices-started app never sources, so that
  path is probed directly the way Kimi's is.
- Interactive launch: `opencode` (native TUI)
- One-shot launch: `opencode run --format json <prompt>`. `run` is the non-interactive surface and
  `--format json` emits one event per line: an envelope of `type`, `sessionID`, and a typed `part`.
- Session resume is by real id. Every event carries `sessionID`, so the first line makes the run
  resumable through `run --session <id>` — no working-directory guess of the kind Kimi's
  `--continue` requires, and therefore no constraint on running two OpenCode nodes in one
  directory.
- **No terminating record.** Unlike every other adapter, nothing in the stream marks the turn
  complete: `step_finish` closes a step, and a step that ran a tool is followed by another step.
  The result is emitted when output closes, via `ProviderParser.finish()`, which the supervisor
  calls from `outputEnded`. Every other parser returns nothing from it.
- MCP and permissions both travel through `OPENCODE_CONFIG_CONTENT`, an inline config that
  outranks the user's global and project files and merges with rather than replaces them. Otto
  writes nothing into the workspace: the `otto` server entry (`type: local`, hour-scale `timeout`
  for the human-blocking `agent.ask_user` and approval tools) exists only in that node's process
  environment, so the user's own servers survive and two nodes cannot overwrite each other's
  scoped token.
- Permission mapping: read-only injects `permission: {edit, bash, webfetch: "deny"}`, which removes
  those tools from the model's list outright rather than prompting — a real guarantee, unlike
  Kimi, whose non-interactive mode has no read-only equivalent at all. Workspace-safe uses
  OpenCode's own policy. Bypass maps to `--auto`, the CLI's only permission flag.
- Models come from the user's own provider credentials (`opencode auth login`, stored in
  `~/.local/share/opencode/auth.json`), so `AgentModelCatalog` offers no hardcoded list and model
  choice belongs to the CLI.
- OpenCode has no `--append-system-prompt` equivalent, so the canvas guidance and the memory
  bootstrap are embedded ahead of the first task prompt the way Codex, Hermes, and Kimi receive
  theirs; continuations skip both.
- Sessions live in a database rather than readable transcript files, so `ProviderSessionStore`
  cannot harvest or restore turns from disk; the live event stream is the only transcript source.

## Grok

Grok Build TUI (`grok`), the xAI coding agent.

- Detection: `grok --version`. The official installer writes the binary to `~/.grok/bin` (and often `~/.local/bin`) and appends that directory to the shell rc file, which a LaunchServices-started app never sources, so those paths are probed directly the way Kimi's and OpenCode's are.
- Interactive launch: `grok` (native TUI)
- One-shot launch: `grok --output-format streaming-messages-json --include-partial-messages -p <prompt>`. The stream is the Messages API `stream-json` shape Claude's parser already understands: `system`/`init` announces `session_id`, assistant/user messages carry tool use, and `result` ends the turn.
- Session resume is by real id: `--resume <session-id>`. Grok stores sessions under `~/.grok/sessions`, but that layout is an ACP update log rather than a transcript Otto can harvest, so TUI stints are not projected back into chat the way Claude and Codex are.
- Permission mapping: read-only is `--permission-mode plan --sandbox read-only`, workspace-safe is `--permission-mode default --sandbox workspace`, and unrestricted is `--permission-mode bypassPermissions --sandbox off`. Both the permission mode and the OS sandbox apply to interactive and prompted runs.
- Models are read from `grok models` at runtime (`* grok-4.6 (default)` / `- grok-4.5`); `AgentModelCatalog` holds a two-entry fallback. Effort is `--effort` with the same low–max ladder as Claude Code.
- Headless runs pass `--disallowed-tools ask_user_question` so clarifying questions go through the otto `agent.ask_user` tool instead of Grok's TUI question card.
- Canvas guidance and the memory bootstrap travel through `--rules`, Grok's extra-system-prompt channel. Continuations keep the canvas rules and skip the bootstrap already stored in the session.
- MCP: no launch flag. Servers come from `~/.grok/config.toml` or the workspace's `.grok/config.toml`. Otto writes only the project-level file and only its `otto` entry (Muse-written `[mcp_servers.muse]` tables are removed; a user-authored `muse` server is kept). Env values are `${VAR}` references expanded by Grok at load time from the process environment, so the file stays identical for every node and two Grok nodes cannot overwrite each other's scoped token. `tool_timeout_sec` is one hour because `agent.ask_user` and permission approvals block on a human answer.
- Otto orchestration v1 still admits only Claude Code and Codex.

## Otto control context

Scoped control values are injected only through the child environment: `OTTO_CONTROL_SOCKET`, `OTTO_CONTROL_TOKEN`, `OTTO_NODE_ID`, `OTTO_WORKSPACE_ID`, and `OTTO_MCP`. Tokens must never be included in provider arguments or diagnostic logs.

The supervisor holds an `AgentControlPlane` (installed by the app once its control socket is listening) and injects these values into every provider and terminal spawn. The agent token is scoped to every capability except globally destructive actions. When the otto-mcp bridge executable is available, adapters additionally register it with the provider CLI — Claude Code via `--mcp-config` plus an `--append-system-prompt` note that teaches the agent to open websites as canvas browser nodes and to ask clarifying questions as plain text, Codex via `--config mcp_servers.muse.command=…`. The bridge process inherits the child environment and authenticates back over the control socket with the scoped token.
