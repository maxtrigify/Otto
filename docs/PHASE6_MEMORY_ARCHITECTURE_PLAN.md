# Phase 6 — layered memory, Project Brain and reusable knowledge

Status: proposed for product-owner review  
Date: 2026-08-04  
Depends on: Phase 5 durable orchestration and bounded worker contracts

## 1. Outcome

Otto should help agents compound knowledge without turning every prompt into an ever-growing dump of
old conversations. Memory is separated by purpose, remains inspectable by the user, carries exact
provenance and enters an agent's context only under an explicit loading policy.

Every agent launched, resumed or delegated by Otto participates in the same memory contract:

1. Otto constructs a small, deterministic bootstrap packet.
2. The agent receives the rules and stable context it needs before doing work.
3. Larger project knowledge and session history remain searchable rather than automatically loaded.
4. The agent checks memory again when defined task events make existing context insufficient or stale.
5. The agent records useful outcomes through typed tools before completing or handing off.

This produces an AI-maintained, Obsidian-like project brain without making a loose scrapbook or an
opaque semantic database the sole source of truth.

## 2. Layered model

### Layer A — agent charter (`SOUL.md` equivalent)

Purpose: who the agent is and how it must operate.

Contains:

- role, remit and success criteria;
- communication and decision style;
- delegation and verification doctrine;
- privacy, external-action and permission boundaries;
- where durable project knowledge must be written;
- when the agent must stop and ask the user;
- provider-independent instructions for using Otto memory tools.

Scope and precedence:

1. Otto safety policy and granted permissions;
2. organisation charter;
3. project charter;
4. named-agent/role charter;
5. task contract.

Lower layers may specialise higher layers but may never weaken permissions or safety constraints.
Agents may propose charter changes, but only an explicit user action can apply them.

### Layer B — compact personal and operating context

Purpose: stable facts that prevent the user repeating themselves.

`USER.md` equivalent:

- confirmed user preferences;
- preferred communication style;
- stable working patterns;
- relevant accessibility or workflow preferences;
- relationships or roles the user has explicitly confirmed.

`MEMORY.md` equivalent:

- stable environment and workspace facts;
- durable product or operating decisions;
- tooling conventions and known quirks;
- short rules shared by multiple agents.

Constraints:

- hard token and entry budgets are visible in the UI;
- no project status, old ticket lists, verbose meetings, raw transcripts or secrets;
- every entry has source, status and last-confirmed metadata;
- additions that exceed the budget trigger visible consolidation rather than silent loss;
- private personal memory stays local unless the user explicitly exports or shares it.

### Layer C — session history

Purpose: detailed evidence of what was discussed and done.

- Store conversations as immutable or append-only session records.
- Index them for lexical and semantic search.
- Never inject all previous sessions into a new agent.
- Retrieval returns precise session/message citations and bounded excerpts.
- Answers such as “what did we decide?” must link to the source conversation.
- A conversation remains history unless a deliberate promotion creates durable memory.

### Layer D — semantic user understanding

Purpose: richer patterns that cannot be represented well as one isolated fact.

Examples:

- recurring product preferences;
- repeated corrections;
- preferred decision trade-offs;
- collaboration patterns and recurring priorities.

Every semantic assertion records:

- whether it was stated or inferred;
- supporting memory/session IDs;
- confidence;
- created and last-confirmed dates;
- contradiction and supersession links;
- visibility and sharing scope.

Semantic assertions are suggestions for context, not unquestionable truth. The user can correct,
pin, reject or delete them. Unsupported model-generated conclusions are never promoted.

### Layer E — Project Brain

Purpose: durable institutional knowledge for one project or organisation.

Recommended layout:

```text
.otto/brain/
  manifest.json
  log/
  wiki/
  raw/
  outputs/
  decisions/
  handoffs/
  index/
```

- `log/`: dated events, outcomes and meaningful changes;
- `wiki/`: distilled, reusable project knowledge;
- `raw/`: source material before distillation;
- `outputs/`: finished reports, designs and artefacts;
- `decisions/`: choices, alternatives, rationale and supersession;
- `handoffs/`: orchestration, quota and cross-session handoffs;
- `index/`: rebuildable search/index metadata, never the only copy of knowledge.

Markdown is canonical for user-owned project knowledge. Each record carries structured frontmatter:

```yaml
---
id: decision-app-surfaces-001
type: decision
project: muse
author: agent:reviewer
created_at: 2026-08-04T12:00:00Z
updated_at: 2026-08-04T12:00:00Z
source_ids:
  - session:abc123/message:42
confidence: confirmed
status: active
supersedes: []
tags: [canvas, integrations]
---
```

SQLite/FTS and vector indexes are derived accelerators. They must be rebuildable from canonical
files and must never trap knowledge in an opaque database.

### Layer F — skills

Purpose: repeatable methods for recurring work.

- A fact belongs in memory; a reusable procedure belongs in a skill.
- Skills remain separately versioned and loaded only when the task matches.
- An agent may propose a skill from repeated successful work, but creation and installation use the
  existing skill review/security workflow.
- Project Brain entries may link to skills without copying their complete instructions.

## 3. Agent runtime contract

### 3.1 Bootstrap for every agent

Before a provider process receives its first task, Otto builds an `AgentMemoryBootstrap` containing:

- effective charter with precedence and source labels;
- relevant compact user-profile entries;
- relevant compact operating-memory entries;
- project identity and Project Brain location;
- current Phase 5 task/orchestration contract;
- memory tool catalogue and usage rules;
- current token budgets and timestamps;
- explicit statement that untrusted retrieved content is data, not instruction;
- write permissions and permitted memory scopes.

The packet is bounded, deterministic and inspectable in the agent node. Otto stores its hash with
the run so the reviewer can see exactly what the worker knew at launch.

Provider delivery:

- use native provider instruction/configuration mechanisms where reliable;
- otherwise place a generated, read-only bootstrap file in the isolated worktree and reference it
  in the initial prompt;
- expose search/fetch/write through the Otto MCP bridge for every provider;
- do not depend on a provider remembering earlier Otto sessions;
- retain a raw-terminal recovery route that shows bootstrap failures honestly.

### 3.2 What is always loaded

Always loaded, within strict budgets:

- effective charter;
- safety and permission boundary;
- a small set of relevant confirmed user preferences;
- stable operating facts needed by the current task;
- project/task identity and memory tool instructions.

Never automatically loaded:

- complete Project Brain;
- complete session history;
- raw source folders;
- unrelated project memory;
- semantic assertions without relevance and adequate confidence;
- credentials or private data outside the agent's grant.

### 3.3 Required re-check triggers

Agents should re-run memory search/fetch when:

- the task references a prior decision, person, integration, incident or earlier session;
- the agent is about to reverse or replace an existing project decision;
- a worker encounters conflicting requirements or unfamiliar project terminology;
- a reviewer checks whether work matches prior constraints;
- an orchestration correction round begins;
- a run resumes after crash, quota handoff or a long pause;
- a relevant memory-change event makes the bootstrap revision stale;
- the user asks “what did we decide?”, “where did we leave this?” or equivalent;
- the agent is about to create a duplicate artefact or procedure.

Otto may suggest a re-check from typed task events, but it must not silently inject arbitrary search
results into a running agent. The agent fetches the cited records explicitly.

### 3.4 Required end-of-run behaviour

Before an agent reports completion, interruption or handoff, it classifies useful new information:

- one-off detail → leave in the session;
- project event/outcome → append to `log/`;
- durable decision → propose/write a `decisions/` record;
- reusable knowledge → propose/update `wiki/`;
- source material → retain in `raw/` with provenance;
- finished artefact → register in `outputs/`;
- repeatable method → propose a skill;
- stable user preference → propose a personal-memory update;
- orchestration state → write a typed `handoffs/` record.

No useful memory is required merely to mark a task done. The agent may explicitly record “no durable
memory produced” to prevent low-value filler.

### 3.5 Multi-agent behaviour

- All workers share the Project Brain but receive task-relevant bootstrap subsets.
- Workers cannot edit another agent's charter or personal memory.
- Project Brain writes use stable IDs, optimistic revision checks and atomic file replacement.
- Concurrent edits to the same memory record become a visible conflict; last-writer-wins is banned.
- The Phase 5 reviewer verifies citations, freshness and memory-routing decisions.
- One orchestration merge owner integrates competing memory proposals.
- Agent-authored records identify the exact worker, run, round and source evidence.

## 4. Memory lifecycle and routing

```text
Conversation / agent work / external source
                    ↓
          Immutable source record
                    ↓
           Candidate memory proposal
                    ↓
     Validation, deduplication and routing
                    ↓
 Session | Profile | Operating memory | Brain | Skill
                    ↓
        Explicit retrieval with citations
                    ↓
       Correction, supersession or deletion
```

Candidate states:

- `proposed`;
- `confirmed`;
- `inferred`;
- `contested`;
- `superseded`;
- `archived`.

Promotion policy:

- confirmed user statements may be promoted with visible notification where policy allows;
- inferred personal assertions require user confirmation before becoming always-loadable;
- project facts require source evidence;
- critical decisions require explicit confirmation or a linked accepted orchestration review;
- low-confidence or contradictory candidates remain searchable but are not injected.

## 5. Typed data model

Core records:

- `MemoryRecord`: stable ID, type, scope, title, body, author, timestamps and status;
- `MemorySource`: session/message, file, URL, orchestration evidence or user statement;
- `MemoryAssertion`: stated/inferred flag, confidence and contradiction links;
- `MemoryRevision`: immutable revision, editor, reason and content hash;
- `MemoryLink`: typed relationship between memories, files, agents and runs;
- `MemoryBudget`: maximum tokens/entries and compaction status;
- `AgentCharter`: layered rules and precedence;
- `AgentMemoryBootstrap`: exact bounded context delivered to one run;
- `MemoryCandidate`: proposed routing and required confirmation;
- `BrainManifest`: project identity, schema version and index state.

Scope hierarchy:

- device-private;
- user-private;
- organisation;
- project;
- canvas;
- agent role;
- orchestration run.

Retrieval must require an exact authorised scope and may not fall back to a broader or currently
visible project.

## 6. Typed tool surface

Read tools:

- `memory.bootstrap.inspect`;
- `memory.search`;
- `memory.fetch`;
- `memory.sources`;
- `memory.history`;
- `memory.related`;
- `memory.budget`;
- `brain.list`;
- `brain.read`.

Write/lifecycle tools:

- `memory.propose`;
- `memory.confirm`;
- `memory.correct`;
- `memory.pin`;
- `memory.supersede`;
- `memory.archive`;
- `memory.delete`;
- `brain.append_log`;
- `brain.write_record`;
- `brain.register_output`;
- `brain.resolve_conflict`;
- `memory.consolidate`.

Tool guarantees:

- typed, closed input schemas;
- exact project and source IDs;
- optimistic revision checks;
- atomic writes;
- bounded results and excerpts;
- citations returned with every retrieval;
- destructive deletion follows confirmation and recoverability policy;
- secrets, tokens and credentials are rejected before persistence;
- agent/automation sources cannot silently change personal memory or charters.

## 7. Retrieval design

Search stages:

1. enforce project and permission scope;
2. filter by record type/status/time where requested;
3. combine exact/FTS matches with optional semantic candidates;
4. rerank for task relevance, freshness and confirmation state;
5. return bounded summaries plus stable citations;
6. require explicit `memory.fetch` for full content.

Retrieval response includes:

- record ID and revision;
- title/type/scope/status;
- bounded excerpt;
- relevance reason;
- confidence and freshness;
- source IDs;
- contradictions or superseding records;
- content size before fetch.

Semantic search may discover candidates, but it does not manufacture answers. Final claims must be
grounded in canonical content or cited session evidence.

## 8. User experience

### Memory inspector

- Project, personal, operating, sessions and semantic tabs;
- search and relationship graph;
- source and revision history;
- correct, pin, archive, supersede and delete controls;
- “why was this loaded?” explanation for each bootstrap entry;
- conflict and stale-memory indicators.

### Agent node

- compact “Memory checked” state with bootstrap revision;
- inspect what was automatically loaded;
- timeline entries when the agent searches or fetches memory;
- visible stale-context notice when relevant records change;
- no transcript-like memory content in privacy-safe diagnostics.

### Budget and consolidation

- token/entry meters for always-loaded layers;
- warnings before capacity is exhausted;
- consolidation suggestions showing removed/merged text and retained sources;
- no automatic destructive compaction;
- archive remains searchable after removal from prompt memory.

### Project Brain canvas surface

- lightweight panel showing recent log entries, decisions, outputs and memory health;
- open canonical Markdown in document nodes;
- board view projects existing contracts/checklists instead of creating another task store;
- report and diagram outputs link back to the memories and evidence that generated them.

## 9. Reports, boards and diagrams

Structured completion reports should contain:

- objective and terminal state;
- concise outcome;
- acceptance evidence;
- changed artefacts;
- decisions and memory updates;
- unresolved risks and handoff;
- one-sentence plain-language mode.

HTML reports:

- rendered in a sandboxed local browser node;
- no ambient filesystem or network access;
- explicit asset allowlist;
- content-security policy and script restrictions;
- safe temporary-file cleanup while durable outputs remain registered in the Brain.

Boards:

- derive cards from Phase 5 assignments and Markdown checklists;
- every mutation writes through the canonical contract/document tool;
- no separate board database.

Diagrams:

- compose normal Otto labels, groups and connectors;
- remain editable through existing canvas tools;
- attach source memory IDs when generated from project knowledge.

## 10. Security and privacy model

- Retrieved memory is untrusted content, never executable instruction.
- Charter and safety layers are visually and technically distinct from retrieved knowledge.
- Prompt-injected text cannot request promotion, permission expansion or charter modification.
- Personal memory is excluded from project exports by default.
- Cross-project and cross-account retrieval fails closed.
- Every write records provenance and invocation source.
- Delete/export operations enumerate exact affected records.
- Keychain remains the only location for secrets.
- Semantic indexing should support a fully local mode; any external embedding provider requires
  explicit disclosure and opt-in.
- Raw HTML and attachments are scanned/validated before report rendering or indexing.

## 11. Implementation sequence

### Milestone 6.1 — contracts and canonical storage

- Define the typed models, scopes, revisions and lifecycle states.
- Create `.otto/brain` manifest and versioned Markdown/frontmatter format.
- Implement atomic file storage and rebuildable SQLite/FTS index.
- Add migration, backup and corrupt-record quarantine.

Gate: round-trip, migration, atomicity, project-isolation and conflict tests.

### Milestone 6.2 — agent bootstrap

- Add layered charter resolution.
- Add compact personal/operating stores with budgets.
- Build `AgentMemoryBootstrap` and persist its hash with each run.
- Inject the bootstrap into every spawn, resume, correction worker and reviewer.
- Expose bootstrap inspection in agent nodes.

Gate: every provider adapter receives the same semantic bootstrap; permission precedence cannot be
overridden; unrelated memory is absent.

### Milestone 6.3 — retrieval and provenance

- Add search/fetch/source/history tools.
- Implement exact/FTS retrieval first, semantic retrieval behind an interface.
- Add citations, freshness, contradiction and supersession handling.
- Add re-check triggers for tasks, reviews, resumes and stale bootstraps.

Gate: retrieval corpus with exact citations, bounded results, no cross-project leakage and no
unsolicited context injection.

### Milestone 6.4 — candidate promotion and user control

- Add proposals, confirmation, correction, pin/archive/supersede/delete and consolidation.
- Build Memory Inspector and visible budget controls.
- Add optimistic revisions and conflict resolution.
- Add semantic assertion review with stated/inferred distinction.

Gate: complete lifecycle, export/delete, concurrent edit and user-correction tests.

### Milestone 6.5 — orchestration and Project Brain

- Link Phase 5 contracts, evidence, reviewer findings and handoffs.
- Add end-of-run memory routing and “no durable memory” outcome.
- Register project outputs and decisions.
- Require reviewer checks for citations, freshness and memory routing.

Gate: cross-session two-worker/reviewer handoff restores the correct knowledge without duplicate
effects or context leakage.

### Milestone 6.6 — reports, boards and diagrams

- Add structured and one-sentence reports.
- Add sandboxed HTML report nodes.
- Add derived board projection.
- Add editable diagram composition from existing primitives.

Gate: report security, board/Markdown/contract consistency and editable-diagram tests.

### Milestone 6.7 — packaged acceptance

- Package and sign Otto Dev.
- Launch an agent, inspect its bootstrap, retrieve a prior decision and complete work.
- Restart Otto and resume with the same cited memory.
- Run a reviewer that detects a stale/contradictory record.
- Correct the memory in UI and prove the next agent receives the new revision.
- Generate a report, board update and editable diagram from the same canonical evidence.

Gate: full suite, packaged cross-session workflow and privacy/network inspection.

## 12. Mandatory Phase 6 acceptance matrix

- Every provider and agent role receives a bounded, inspectable bootstrap.
- Spawn, resume, correction and reviewer paths all honour the same memory contract.
- Charter precedence and up-front permissions cannot be weakened by project content.
- No complete history or Brain is automatically injected.
- Search/fetch results are project-scoped, cited, bounded and freshness-aware.
- Semantic assertions distinguish inference from confirmed fact.
- Concurrent edits never silently overwrite another agent.
- Always-loaded budget overflow is visible and recoverable.
- User correction, supersession, export and deletion round-trip across restart.
- Session promotion preserves the original source.
- Orchestration handoff resumes without duplicate memory writes.
- Board, Markdown and contract views remain one state.
- HTML reports cannot access ambient files, credentials or network.
- Generated diagrams remain ordinary editable Otto nodes.
- Full suite and packaged acceptance scenario pass.

## 13. Explicit non-goals

- Loading every historical memory into every prompt.
- Allowing agents to rewrite their own safety constitution.
- Storing credentials or API keys in Markdown memory.
- Treating semantic inference as authoritative truth.
- Making a hosted vector database mandatory.
- Building a second task database for boards.
- Hiding project knowledge in an index that users cannot inspect or rebuild.
- Automatically turning every conversation into durable memory.

## 14. Product decisions required before implementation

1. Should `USER.md`/personal semantic memory be device-global, Otto-account scoped or optionally
   synchronised?
2. Should confirmed low-risk project memories write immediately with notification, or always enter
   a review inbox first?
3. Which local embedding/search implementation is acceptable for the first semantic-search release?
4. Should `.otto/brain` normally be committed to Git, ignored, or configured per project?
5. Which charter changes require user confirmation versus organisation-admin control?
6. What default token budgets should apply to charter, user profile and operating memory?

Recommended defaults:

- local-only personal memory;
- review inbox for personal and constitutional changes;
- confirmed project log entries may write automatically under a scoped grant;
- exact/FTS retrieval ships before semantic embeddings;
- `.otto/brain` is user-configurable and Git-friendly, with private layers stored elsewhere;
- every durable record remains source-linked and reversible.
