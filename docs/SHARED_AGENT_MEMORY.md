# Shared memory for sessions and bots

Otto owns memory selection, independently of the model or harness executing a task.

| Layer | General session | Bot chat or team turn |
| --- | --- | --- |
| Confirmed personal preferences | Shared across Otto on this device | Same shared preferences |
| Confirmed workspace operating memory | Current workspace | Current workspace |
| Relevant confirmed project wiki and decisions | Current workspace's Project Brain | Same Project Brain |
| Confirmed private bot lessons | None | Only the active, linked profile |
| Conversation history | This session | This private chat or team room |

`AgentTaskMemory` composes a fresh context selection from the existing stores. Project retrieval uses the task text and a 1,200-token packing budget; private bot memory uses a separate 1,000-token budget. Compact personal and operating stores retain their existing character budgets. These are approximate token budgets, not tokenizer measurements.

`ApplicationServices` resolves bot ownership from persisted node definitions or isolated team-runtime routing, never from a profile name in a prompt. `AgentSupervisor` adds the context before new and resumed one-shot provider launches and interactive prompt submission. The visible transcript retains the original user message. Hidden team turns explicitly compose the same memory selection without importing private-chat history.

The context travels through the existing provider adapters, including Otto Harness. Provider session history is not the memory database. Refreshed memory tells the agent to treat old selections as potentially stale; this does not erase historical messages already stored by an external provider.

## Learning and review

- Shared personal preferences: `memory.propose` with `personal`.
- Workspace habits: `memory.propose` with `operating`.
- Project facts and procedures: `brain.write_record` with sources.
- Private bot lessons: `bot.memory_add` or `bot.memory_replace`.

Agent and automation writes are confirmed immediately, including edits to trusted confirmed notes. Sources beginning with web:, browser:, email:, inbox:, url:, http://, https:// or bot-message: quarantine the write as proposed. This provenance gate limits prompt injection; it is not a truth checker. Only user calls may confirm, archive or delete records. Compact personal/operating writes go directly to their stores; budget overflow stays in the inbox without evicting existing entries. Secret scanning covers bodies, titles, sources and tags.

Archived, expired, superseded and deleted records are excluded from task context. A canonical Brain with no eligible bot notes does not fall back to legacy JSON notes. Legacy migration respects deletion tombstones so a restart does not recreate deleted notes.

Ordinary turns retrieve confirmed wiki and decisions. Explicit recall phrases (for example “do you remember” or “last time”) additionally retrieve a bounded confirmed project wiki/decision/log pack with fetchable IDs and the confirmed compact entries. Trivial prompts do not trigger recall. Sessions never receive agent-role records. An agent should write durable project lessons as they are learned, with sources. Private bot knowledge must not be promoted to shared memory without authorization.

## Boundaries

This implements shared memory delivery and reviewed lesson reuse. It does not add connector ingestion, semantic embeddings, a scheduled consolidation worker, automatic model-weight training, or deletion of external provider transcripts. Bots share project knowledge within the workspace whose services run them; this does not add cross-workspace access.

The same process-level filesystem permissions still apply. A private memory scope controls Otto's tools and context routing; it is not an operating-system sandbox for an unrestricted local agent.


New chats default to the legacy workspace project and its `.otto/brain`, enabling project memory and automatic run logs. An explicit Unassigned selection is persisted and opts out of project memory; captured in-flight contexts remain fixed. Old state did not distinguish an absent selection from an explicit clear. Migration conservatively preserves unassigned existing chats supplied by the workspace; newly created chats adopt the workspace default. Explicit clears made with this version survive restart.
