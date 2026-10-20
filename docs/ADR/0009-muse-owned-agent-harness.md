# ADR 0009: Otto-owned agent harness and memory boundaries

## Status

Accepted and implemented. OpenAI, Anthropic, xAI, and Moonshot are direct model backends. Native
CLI harnesses remain available as compatibility and specialist alternatives.

## Decision

Muse owns the agent loop: current system instructions, tool execution, canonical conversation
history, session identity, limits, and events. Model providers implement `HarnessModelBackend` and
receive an opaque, turn-local continuation value when their protocol needs one.

Muse session IDs are provider-neutral. A conversation can therefore move between model backends
without losing its Muse-owned history. Provider response IDs are not session identity and are not
long-term memory.

## Memory model

Memory has four deliberately separate layers:

1. **Identity and instructions** — the current bot profile is authoritative system context and is
   rebuilt on every turn. It is not copied into visible chat or persisted as an old chat message.
2. **Working conversation** — user and assistant text is stored locally by the harness under
   `~/Library/Application Support/Muse/Harness/Sessions`. Files and their parent directory are
   user-only, and history is bounded before persistence.
3. **Durable project memory** — Project Brain records, compact personal memory, operating memory,
   charters, and profile-scoped curated notes are retrieved by the existing memory bootstrap
   provider and injected as current system context for each run.
4. **Audit and curation** — run history records what happened. Durable facts and decisions are
   explicitly promoted to Project Brain rather than inferred by blindly saving every transcript.

This means editing a bot's instructions takes effect on its next message, resuming preserves the
conversation, and switching model providers does not transfer ownership of memory to that vendor.

## Compatibility

The 0.1.22 OpenAI runtime used an OpenAI response ID as its session ID. The owned harness accepts
that identifier once as legacy continuation state, creates a new `muse_…` session, and emits the
new stable ID. New turns reconstruct context from Muse's local transcript.

The persisted `AgentProvider.openAI` case is retained for profile compatibility, but the UI calls
it **Muse Harness** and stores provider-prefixed model IDs. It routes OpenAI and xAI through their
Responses APIs, Anthropic through its native Messages API, and Moonshot/Kimi through its
OpenAI-compatible Chat Completions API. Every backend receives the current bot profile as system
context, returns tool requests to the same Muse-controlled executor, and persists only canonical
user/assistant text as durable session history.

Claude Code, Codex, Grok, Hermes, Cursor, Kimi CLI, and OpenCode remain available through their
native harness adapters. These are separate products with their own private conversation state;
they still receive Muse's current profile and memory bootstrap but do not replace the owned path.
