# Live space switching

Space switching changes the visible workspace inside one app process. It never terminates
Otto, stops an agent, or resumes a replacement provider process as part of navigation.

`OttoSpaceController` retains one `OttoSpaceRuntime` for each opened workspace path. Each
runtime owns its CanvasStore, ApplicationServices, control socket, supervisors, tool registry,
voice session and WorkspaceUIState. Startup is owned by the runtime, not a cancellable view
task. Returning to an opened space reuses those exact objects. Unopened spaces are not started.
The profile registry and device-wide provider account store are shared; workspace data and
permissions remain scoped to their original services.

The destination database is migrated and restored before the active preference changes. If
opening or decoding fails, navigation fails in place and leaves the current agents running.
Saved workspaces retain the existing unreadable-snapshot protection.

The workspace stack keeps opened views mounted to retain drafts, selections and editor state.
Only the active space can receive keyboard/mouse input or expose accessibility controls.
Window-wide monitors explicitly check space visibility. Browser renderer reporting and pruning
use the owning runtime, so another space cannot prune or write its browser state.

Completion subscriptions cover every opened space. Notification navigation selects the owner
before opening the conversation. The on-screen buddy follows the visible space; completion
banners for other spaces remain available. Voice input and playback are muted in hidden spaces
without cancelling outstanding voice tool calls.

Quitting and update restarts still stop processes: their existing quit policy checks all opened
spaces and flushes all their stores. Live navigation does not promise survival across an app
quit, crash, OS shutdown, or sleep. Installing this change into an older running app requires
one normal restart; do not interrupt active work to apply it.

Validation lives in `SpaceSwitchingTests` (supervised shell process, stable PID/run ID during
navigation, completion while hidden, output, persistence, runtime reuse and corrupt destination)
and `VoiceSessionTests.backgroundSpacePreservesDelegation`. The native preview also exercises
independent Home drafts through A → B → A with no relaunch.
