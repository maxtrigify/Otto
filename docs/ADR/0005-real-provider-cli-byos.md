# ADR 0005: Real provider CLIs remain the execution substrate

- Status: Accepted
- Date: 2026-08-03

## Context

Muse presents coding agents as readable native conversations, but Claude Code, Codex and future
providers already supply mature authentication, subscription access, tool execution, permission
prompts and session continuity through their own CLIs. Replacing them with direct metered API calls
would change customer economics and duplicate provider behaviour. A terminal-only presentation,
however, is unnecessarily difficult to read and operate.

## Decision

Muse will supervise the real provider CLI in a PTY and treat that process as the execution source of
truth. The native conversation view is a projection over the provider session, with the raw terminal
always available for recovery and unsupported interactions. Muse users bring their existing provider
installation, account and subscription; API-backed execution is an explicit alternative with a
visible spend policy, not the default.

Provider prompts must be delivered byte-for-byte. Muse may route a prompt to a destination but may
not paraphrase its body. Provider-specific adapters own launch, resume and output parsing, while the
shared runtime owns bounded output, lifecycle, permissions and audit events. ACP or another protocol
may replace a CLI only when it offers equivalent provider coverage, subscription use, session
continuity and permission semantics.

## Consequences

- The native UI can improve readability without forking provider execution semantics.
- Provider CLI compatibility and transcript fixtures are release gates.
- Users do not need a separate metered API key for the normal coding-agent path.
- Raw terminal access remains a required escape hatch rather than the primary product surface.

