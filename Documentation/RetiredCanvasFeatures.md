# Retired canvas features

The current app uses Home, Chat, Documents, Dashboards, Browser, Activity and Automations.
The spatial canvas and standalone widgets are retired product features.

Removed from the application:

- Standalone widget creation, editing, rendering, management, and tool APIs.
- Widget script runner and automatic background scheduler.
- Widget pinning controls and execution of saved widget pins on Home.
- Canvas lifecycle, whiteboard, spatial staging, and layout recipe tool APIs.
- Voice grammars and agent instructions that route to those retired APIs.
- Unreachable canvas creation sheets, recipe preferences, the unused recipe module,
  and the bundled Excalidraw runtime.

## References intentionally retained

`CanvasStore`, `OttoCanvas`, canvas IDs and permission scopes still underpin live sessions,
browser tabs, terminals, media, persistence and isolation. Removing or renaming them is a
separate storage migration, not dead-code deletion. Their presence does not expose a canvas UI.

`NodeKind.widget`, widget manifest/runtime model types and `HomePin.Source.widget` remain
serializable so saved workspace snapshots and pins can still be decoded. Saved widget pins
are not rendered or executed; Markdown pins remain available. The old `Widgets` navigation
value falls back to Chat. No user package folders or saved files are deleted.

Historical changelogs, design plans and bundled third-party documentation may refer to older
features. These are historical records, not active capabilities. Agent prompts and the live
tool registry must not advertise widget, canvas, whiteboard, recipe or layout APIs.
