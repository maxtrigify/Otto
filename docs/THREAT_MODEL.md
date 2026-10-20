# Otto threat model

## Protected assets

- Workspace files, Git history, worktrees, credentials, control tokens, voice audio, prompts, and
  terminal output.
- User intent: content displayed by browsers, documents, terminals, or agents is data and never an
  authorization signal.

## Trust boundaries

- The local UI is trusted to request tools, but every request still passes through typed decoding,
  scope checks, risk classification, and confirmation checks.
- Local agents receive short-lived, revocable grants with only the scopes required for their run.
- Browser pages, document text, terminal output, provider output, and voice transcripts are
  untrusted content. Otto does not convert displayed content into a tool call automatically.
- Workspace file operations resolve canonical paths and reject traversal and symlink escapes.
- Credentials remain in Keychain or process launch environments and are excluded from recipes,
  workspace snapshots, event payloads, and diagnostic records.
- A remote `ottod` instance is authoritative for its PTYs and journal, but is trusted only inside an
  authenticated SSH tunnel. It exposes no TCP listener. Every multiplexed request still carries a
  256-bit token stored in an owner-only file; connection origin alone is not authentication.

## Required controls

- Destructive tools require explicit confirmation; missing scopes always deny.
- Editing agents default to isolated Git worktrees, and dirty worktrees cannot be deleted.
- Control grants expire and can be revoked individually or by actor when a node/session closes.
- HTTP browser URLs reject embedded credentials and control characters.
- Provider prompts reject NUL bytes and are capped at 256 KiB.
- Runtime scrollback and event history are bounded. Diagnostic events contain metadata, not prompts,
  file paths, terminal output, browser content, voice transcripts, or secrets.
- Remote sockets, state directories, journals, and token files are owner-only. Socket descriptors are
  close-on-exec and suppress `SIGPIPE`; frames, sessions, input, terminal dimensions, event pages,
  journal growth, and transfers are bounded. Workspace roots are registered at daemon launch, and
  file transfer resolves parent directories and symlinks before atomic writes.
- Remote token rotation uses an owner-only temporary file plus atomic rename. The daemon changes its
  in-memory token only after durable replacement succeeds; the Mac updates Keychain only after the
  daemon acknowledges, so the old token is immediately revoked without a split-brain credential.
- Remote upgrades require an Ed25519 signature from a configured release key, exact SHA-256 and size,
  the local platform and supported protocol, and a strictly newer version/build. Hash and size are
  checked before staging, after staging, and after installation. macOS additionally requires a valid
  code signature and uses an atomic swap; Linux retains the previous inode with a same-directory hard
  link before atomic replacement. Both retain one rollback artifact. Verification keys come from the
  trusted Mac release configuration, never from the host being upgraded.

## Abuse cases covered by tests

- Wrong, expired, and revoked socket tokens; recursive spawning; missing scopes; unconfirmed
  destructive calls; traversal and symlink escape; recipe credentials; malicious browser URLs;
  oversized/NUL prompts; child-process cleanup; bounded output; and crash-safe SQLite restoration.
- Remote coverage additionally includes wrong tokens, traversal and symlink escapes, transfer limits,
  session limits, persistent PTYs across client disconnect, monotonic journal replay, and reconnect
  cursors over a private Unix socket. Upgrade coverage includes untrusted keys, artifact tampering,
  downgrade/platform/protocol rejection, unsafe destinations, atomic replacement, and forced
  post-install validation rollback.

## Residual risks and release gates

- A provider CLI executes with the permission mode selected by the user; unrestricted mode remains
  inherently high risk and must be explicit.
- The Linux user service keeps portable systemd restrictions that do not prevent supervised tools
  from doing their work. It intentionally does not use `MemoryDenyWriteExecute`, because that
  inherited restriction blocks JIT-based provider CLIs; authentication, workspace confinement,
  resource bounds, and the absence of a public listener remain the primary remote controls.
- Web content can socially engineer a user. The app must keep origin labels visible and must never
  treat page text as instructions.
- Notarization, hardened-runtime entitlements, dependency review, and external penetration testing
  remain release gates rather than runtime controls.
- Initial remote bootstrap supports user-level macOS hosts. Linux VPS packaging, host-key enrollment
  UX, trusted-key delivery through the client upgrade flow, SSH disconnect and upgrade chaos on two
  real machines, and external review remain remote release gates.
