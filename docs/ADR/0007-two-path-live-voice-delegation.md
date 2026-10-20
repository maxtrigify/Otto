# ADR 0007: Two-path live voice delegation

## Status

Accepted and implemented for the public API surface available on 2026-08-04.

## Decision

Muse separates voice interaction into two independent paths:

1. The media path uses the selected Realtime voice provider for low-latency listening, spoken
   acknowledgement, interruption, and short direct workspace actions.
2. A compound request is handed to `muse.delegate_tasks`. Muse returns an accepted tool result
   before slower work begins, then GPT-5.6 produces a strict structured plan containing one to six
   self-contained worker briefs. Muse launches those workers concurrently through `agent.spawn`.

The task planner is bounded to installed providers, preserves the user's complete objective, uses
workspace-write permissions, and isolates concurrent coding workers in worktrees. Existing agent
nodes provide durable status and the existing voice-notification path groups completed, failed, and
waiting results without blocking the microphone event loop.

## Public-platform boundary

This is the application architecture shown by GPT-Live, implemented on the public OpenAI APIs. It
is not a claim that Muse has OpenAI's private GPT-Live media frontend or Instant Connect service.
`gpt-live-1` is not yet public in the API. Muse therefore uses `gpt-realtime-2.1` over its current
WebSocket transport and GPT-5.6 through `/v1/responses`. The transport capability remains marked
turn-based because server VAD still commits turns.

OpenAI's public WebRTC interface requires an SDP-capable WebRTC client and a call to
`/v1/realtime/calls` (or an ephemeral-token flow). WARP/SPED and OpenAI's coordinated Instant
Connect path are not public API switches. Muse will add a native WebRTC transport behind the
existing `VoiceProviderCapabilities` boundary when the macOS client dependency and rollout data
justify it; only a true continuous provider may declare full-duplex audio.

## Consequences

- Talk can accept another request while planning and worker startup are in flight.
- Several independent tasks begin together instead of being serialized by the voice model.
- Spoken completion updates reuse the same privacy-bounded status path as manually launched agents.
- Multi-task reasoning requires a stored OpenAI API key, including when Grok is the conversation
  engine.
- Actual listen-while-speaking inference and one-round-trip WARP establishment remain dependent on
  a future public GPT-Live transport/model contract.
