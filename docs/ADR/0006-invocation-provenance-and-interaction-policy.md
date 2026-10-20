# ADR 0006: Tool provenance is separate from interaction privilege

- Status: Accepted
- Date: 2026-08-03

## Context

Muse exposes one typed tool registry to the native UI, voice, CLI, MCP-connected agents,
automations and internal services. Data scopes alone cannot express whether a caller may interrupt
the person using the app. A background agent may legitimately create durable content while lacking
authority to switch the visible canvas, move the camera, raise a window, take keyboard focus or make
Muse speak. Using only the globally active canvas also allows background work to land in the wrong
workspace when the user changes context.

## Decision

Every tool invocation carries authenticated provenance: source category, source node when present,
source canvas, optional explicit target canvas and a separate set of interaction privileges. Data
and process scopes continue to determine what state a caller may read or mutate; interaction
privileges determine whether it may affect the user's current view or audio.

Agent and automation grants default to no interaction privileges. Their control tokens bind the
source node and canvas at issuance, so request payloads cannot forge provenance or redirect work to
another canvas. Canvas mutations resolve an explicit target without changing `activeCanvasID`.
User UI, intentional voice commands and direct CLI actions may receive interaction privileges under
their own policy. Unsupported future node payloads are retained opaquely rather than converted to a
known type during persistence.

## Consequences

- Background work can continue on its owning canvas while the user works elsewhere.
- Focus, viewport, visible-canvas and speech operations are centrally deny-by-default for agents and
  automations.
- Cross-canvas delegation requires a separately authorised grant instead of a caller-supplied UUID.
- New interactive tools must declare their interaction privilege in the registry policy and add
  source-combination tests.
- Completion and permission needs must surface as non-interrupting attention state until the user
  chooses to navigate to them.

