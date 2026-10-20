# ADR 0001: Native shell and initial distribution model

- Status: Accepted for alpha
- Date: 2026-08-01

## Context

Muse needs a fluid spatial canvas, ordinary macOS controls, embedded terminal processes, WebKit previews, and microphone access. The execution plan asks Milestone 0 to settle the UI split and to avoid discovering late that App Store sandbox rules conflict with user-authorised CLI processes.

## Decision

Muse will use SwiftUI for the application shell, commands, inspectors, and settings. The canvas is currently a SwiftUI scene backed by world-coordinate models; it may move behind an AppKit `NSView` boundary when the 50-node performance fixture demonstrates that custom hit testing or layer management is necessary. Runtime, tools, persistence, and provider adapters cannot depend on the UI target.

The alpha will be distributed directly as a Developer ID signed and notarised application. Hardened runtime remains enabled, with narrowly scoped entitlements. Mac App Store distribution is not an alpha requirement because launching user-selected coding CLIs and managing PTYs are core product behaviours.

## Consequences

- The product stays fully native while retaining an explicit performance escape hatch.
- The package dependency graph enforces that the shared state model can serve UI, voice, MCP, and CLI clients.
- App sandbox feasibility remains a documented spike, but it cannot block direct alpha distribution.
- Any move to AppKit canvas rendering must preserve the existing `SceneTransform`, commands, and persisted world coordinates.
