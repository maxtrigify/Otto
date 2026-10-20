# Agent files, rendered documents, and agent chaining

*Written 2026-08-04 after a full infrastructure survey. Grounded in what exists in this tree today.*

## What already exists (survey results)

| Capability | State |
|---|---|
| Markdown renderer (headings, code/diagram fences, tables, lists) | `MarkdownMessageView` — used by agent chat **and markdown nodes** (wired 2026-08-04) |
| File-backed nodes with live reload + conflict banner | `WorkspaceDocumentStore.watch` + `DocumentConflictPolicy` in `MarkdownBody` — working |
| Agent tools to create/open/edit docs | `document.create/open/replace/read/append` (SpatialWorkflowTools.swift) |
| Agent A prompting agent B | **Already live** via otto-mcp: `agent.spawn`, `agent.send_prompt`, `agent.get_result`, plus `event.wait` for push-based completion triggers |
| Message → other agent handoff in UI | Shipped 2026-08-04: ↗ menu on any assistant message sends it as a prompt to another agent node |
| Durable multi-agent contract | `OrchestrationRun` + `OrchestrationRunStore` (assignments, reviewer+rubric, rounds, spend policy, permission grant, phase machine) with 12 `orchestration.*` MCP tools |
| Orchestration loop engine | `OrchestrationCoordinator` — **tested but never constructed in production**; `OrchestrationWorkerExecutor` / `OrchestrationReviewExecutor` have no conformances |
| Orchestration UI | `OrchestrationSummaryCard` — display-only, no start/cancel/approve |
| Chain edges | `NodeContent.connector(sourceNodeID:targetNodeID:)` persisted but always nil; `ConnectorBody` draws a decorative bezier |
| Recipes | Reproduce canvas *shape* only — no prompts, no agentDefinition, no ordering |

## Feature A — Files on agent nodes

Goal: "Fable, write a plan" → a rendered plan.md is one click away from the chat, live-updating as the agent edits it.

**A1. Files tab on agent nodes.** Extend the CHAT / TERMINAL surface bar with a FILES surface
(`NodePresentationMode` gains `.files`, or a lighter per-node `@State` + persisted selection in
`OttoNode.additionalPayload`). Contents: the files this agent touched, from two sources that
already exist:
- `structuredResult.filesChanged` + the per-tool-call transcript entries (kind `.toolCall`,
  detail Edit/Write, text = path)
- documents the agent created via `document.create` on this canvas

Render selection with `MarkdownMessageView` for md/text, monospace for code, via
`WorkspaceDocumentStore.read/watch` (workspace-confined by design). A file row's overflow menu:
"Open as canvas node" (`document.open`), "Reveal in Finder".

**A2. Diagrams.** Mermaid/PlantUML fences already render as labeled DIAGRAM code blocks; ASCII
diagrams render correctly in monospace. True Mermaid rendering needs a WKWebView with bundled
mermaid.js (no CDN) — worth doing once, as a `CodeBlockView` enhancement, so it lights up in
chat, markdown nodes, and the files tab simultaneously. Whiteboard shapes
(`whiteboard.create_shapes`) remain the native option for agent-drawn diagrams.

**A3. Missing tool:** `document.attach(nodeID, relativePath)` so an agent can associate an
existing file with a node without creating a new one.

## Feature B — Agent chaining ("Fable plans → Sol implements → Fable reviews")

Three layers, cheapest first. Each is independently useful.

**B1. Manual handoff (shipped).** The ↗ menu on any assistant message prompts another agent
with that message plus provenance. Covers "hand that plan over to Sol" today. Follow-ups:
- "Hand off…" should also offer "New Claude Code agent / New Codex agent" targets that spawn
  first (quickLaunchAgent) then deliver.
- Optionally set a connector node between the two cards to make the chain visible.

**B2. Conductor agent (works today, needs polish).** Any agent can already run the whole chain
through otto-mcp: spawn/prompt peers, `event.wait` on `agent.run_completed`, read results,
forward them. That means: tell one Claude agent "coordinate: plan with me, implement on a Codex
agent, review back here" and it can. Polish needed:
- A system-prompt recipe (append to `ottoCanvasGuidance`) teaching the conductor pattern:
  claim work via `orchestration.*`, wait via `event.wait`, never poll.
- Guard rails: cap agent-initiated spawn fan-out and `send_prompt` depth (loop prevention);
  the audit trail already records every call per-agent token.

**B3. Native pipelines (the real feature).** Wire the tested-but-unused engine:
1. Production `OrchestrationWorkerExecutor`/`ReviewExecutor` bridging
   `OrchestrationAssignment.workerNodeID` → `AgentSupervisor.spawnOneShot`/`resumeOneShot`
   (results from `structuredResult`, evidence = filesChanged/commandsRun).
2. Construct `OrchestrationCoordinator` in `ApplicationServices`; add sequential dependencies
   (assignment `dependsOn: [UUID]` or chained single-worker rounds) for plan→implement→review.
3. Make `OrchestrationSummaryCard` interactive: start/cancel/approve-escalation; a Cmd+K quick
   action "New agent pipeline…" that builds the run from a simple form (or from connector edges
   drawn between agent cards).
4. Adopt `connector(sourceNodeID:targetNodeID:)` as the visual pipeline edge; draw real
   node-to-node beziers in `ConnectorBody`.

## External reference: block/buzz (reviewed 2026-08-05)

Buzz (https://github.com/block/buzz) is Block's self-hostable human+agent workspace: a Nostr
relay where every message, patch, approval, and workflow step is a signed event in one
append-only log; agents are first-class members with keypair identities; coordination is room
membership + event subscriptions. Otto converged on the same shape process-locally (event bus,
scoped agent tokens, canvases, approval gates, event.wait).

Adopted from it (2026-08-05): **the audit chain is readable, not just written** — the existing
SQLite audit sink gained a query API and an `audit.recent` tool so users and conductor agents
can see what every actor actually did (tool names and outcomes, never payloads).

Worth revisiting later:
- Their relay/room model (WebSocket, JSON events, membership-scoped) as the reference for how a
  remote Hermes agent should join a canvas, instead of tunneling the Unix socket.
- Branch-as-room: a worktree agent's canvas group carrying its diff/CI/approvals as one stream.
- Not adopting: the Nostr/keypair substrate — its payoff is federation across untrusted hosts,
  which is not Otto's problem; local-first scoped tokens stay simpler and equally auditable.

## Suggested order

1. ~~Markdown nodes render properly~~ (done) · ~~manual handoff~~ (done)
2. A1 files tab (highest daily value, all parts exist)
3. B2 conductor guidance + fan-out guard rails (unlocks voice-driven chaining cheaply)
4. B3 native pipelines (wire coordinator, interactive card, connectors)
5. A2 Mermaid WKWebView rendering · A3 document.attach
