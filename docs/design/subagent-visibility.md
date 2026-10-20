# Subagent visibility

Reference: https://x.com/chiziaruhoma/status/2096914349403128128/video/1
Paper: https://app.paper.design/file/01M1NQS8VTQC85KZXPXWHSVTGB/2-0
Artboard: “03 · Subagents — live activity & motion”.

## Interaction

The conversation contains a collapsible Agents panel. Its header counts running, starting,
waiting, done, failed, stopped, and unconfirmed children. Selecting a child reveals its task,
reported activity, model when available, elapsed time, and failure information. A maximum of
eight rows is shown initially; the user can reveal the rest. Activity histories retain the
latest 40 entries and the detail view shows the latest 12.

Blue dashed connections and rotating indicators animate only for running/starting children.
Transitions take 200 ms. Reduce Motion disables movement and uses static status icons. Colors
follow Otto's palette except conventional blue activity and green success indicators.

## Provider coverage and honest limits

| Harness | Source of child information |
| --- | --- |
| Claude Code | Agent/Task calls, parent_tool_use_id, task_started/progress/notification/updated, tool results. Background Bash and Monitor jobs also appear. |
| Codex | collab_tool_call receiver_thread_ids and agents_states; legacy explicit agent_task/subagent items; attributed local rollout metadata when stdout omits child identities. Completion of spawn/wait itself is never child completion. |
| Hermes | Gateway subagent.start/tool/complete payloads, identities, nesting, status, model and usage. |
| Cursor | taskToolCall arguments/results, including isBackground. Background acknowledgement remains running until a terminal result is exposed. |
| Kimi | Task/Agent function calls and matching tool results in print output. |
| OpenCode | task/subagent tool_use parts and their state. A build that only emits completed tool parts can only show the completed child. |
| Grok | Claude-compatible stream, Agent/Task/task/spawn_subagent tools and matching results. |
| Otto owned API harness | Otto agent.spawn and event.wait delegation; the supervisor projects the actual child state. |

Every AI harness can select delegated mode. A shell is not an AI harness and cannot select
that execution strategy. Ordinary direct mode does not prohibit native delegation.
Otto-tool agent and terminal spawns are linked to the requesting parent turn, across providers.
Native children are not separately controllable Otto nodes; selecting a row inspects it.

Bot profiles pass their execution strategy to this same runtime. Team turns have no default
inactivity deadline: quiet reasoning, native waits, and background children can take longer
than five minutes without Otto stopping them. Normal completion, process failures, and user
Stop still end the turn. Embedders may explicitly opt into `teamRunInactivityTimeout`; that
policy is intentionally not enabled by the app.

Never invent tool attribution, child IDs, usage, percentages, or success. Native providers
that don't emit child IDs cannot supply a detailed tree. Quiet periods and wait timeouts do
not finish a child. A parent run terminating without a native child result marks that child's
outcome unconfirmed; stopping/interruption marks unresolved children stopped. Otto-owned
children retain their independently supervised status.

Detailed child logs depend on the provider stream. Kimi/OpenCode/Cursor versions that expose
only task boundaries cannot provide the same live tool log as Claude or Hermes. For Codex, a
bounded observer checks local session metadata every two seconds during the parent run and once
after completion. It reads at most 128 recent candidate headers (up to 64 KiB each) and 64 KiB tails only for direct
children whose metadata names the confirmed parent session. It does not infer parentage from
timing or filenames. The bounded tail means action counts are a lower bound for long children.

## Verification

Full app build passed. The focused run passed 78 tests across six suites, including
six native panel renders at 390px and 960px (expanded, child detail, collapsed).
The inactivity-policy follow-up passed all 35 bot-team tests, including quiet workers
with and without waiting children, manual Stop, and explicitly configured timeouts.

- A real Claude Code run launched two native children and delivered separate task lifecycle
  records and results. A sanitized capture is checked in as claude_children_live.jsonl.
- A real installed Codex run emitted wait events with empty receiver IDs. Its two child
  rollouts expose explicit parent identities and terminal results; an opt-in capture test
  exercises the fallback reader against those files. Synthetic fixtures cover cache refresh
  and exclusion of unrelated sessions.
- Remaining provider coverage uses structured protocol fixtures, not authenticated live runs.
- Regression cases cover overlapping children, correct attribution, background acknowledgement,
  timed-out waits, stopped watchers, nested text isolation, and delegated mode availability.

Protocol references:
- https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/types.py
- https://github.com/openai/codex/blob/main/codex-rs/exec/src/exec_events.rs
- https://docs.cursor.com/en/cli/reference/output-format
- Hermes installed gateway source: tui_gateway/server.py subagent event projection.
- Grok installed docs: docs/user-guide/16-subagents.md.


## Headless background-command lifetime

Claude print-mode launches, including resumed turns, set
`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`. Claude's background Bash/Agent tasks and automatic
backgrounding are process-scoped, so a final reply must not promise they will finish after
that process exits. Interactive Claude launches are unchanged. Native foreground subagents
remain available; Otto `agent.spawn` provides supervised asynchronous delegation.

Long-running commands use `terminal.run` and retain their terminal ID. `terminal.wait`
timeouts mean the command is still running, not that it failed or completed. Otto owns this
process independently of the parent provider turn; later calls can retrieve its result.
Finishing a reply does not schedule a follow-up, and these processes do not survive Otto
itself shutting down. Existing abandoned native task IDs are not revived by this change.

Regression coverage checks fresh/resumed Claude launch configuration and a real shell command
that remains alive after its parent turn exits, then completes through `terminal.wait`.
Claude setting reference: https://code.claude.com/docs/en/env-vars#claude-code-disable-background-tasks
