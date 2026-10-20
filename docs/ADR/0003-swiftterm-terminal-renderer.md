# ADR 0003: SwiftTerm for native terminal rendering

- Status: Accepted
- Date: 2026-08-02

## Context

Muse must retain the native TUI behavior of supported provider CLIs. A plain SwiftUI `Text` transcript cannot correctly implement cursor addressing, alternate screens, colours, Unicode cells, mouse reporting, bracketed paste, selection, or terminal resize.

## Decision

Use SwiftTerm 1.15.0, pinned exactly through Swift Package Manager, as the AppKit terminal-emulation view. Muse retains its existing supervised PTY and process lifecycle; SwiftTerm renders the byte stream and forwards keyboard/mouse bytes and resize events through the scoped Muse tool registry.

Muse keeps its own bounded transcript for runtime status, search, run history, voice-safe result extraction, and recovery. Incremental render offsets are tested so scrollback eviction or switching to a historical run resets the emulator instead of corrupting its screen.

OSC 52 clipboard reads remain denied by SwiftTerm's default delegate behavior. Native selection/copy remains available. Metal rendering is not enabled by default; the SwiftTerm shader bundle is still packaged under `Contents/Resources` so a reviewed future GPU path does not depend on build-machine paths.

## Consequences

- Provider TUIs receive VT100/xterm rendering, mouse input, bracketed paste, selection, and resize behavior from a maintained emulator rather than a new implementation.
- SwiftTerm's MIT notice is distributed in `THIRD_PARTY_NOTICES.md`.
- Package and renderer upgrades require golden provider fixtures, the full PTY/control regression suite, package-resource verification, and a rendered accessibility review.
- SwiftTerm's current accessibility behavior still needs hands-on VoiceOver verification before the v1 accessibility gate can pass.
