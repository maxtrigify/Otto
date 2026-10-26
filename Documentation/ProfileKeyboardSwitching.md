# Profile keyboard switching

Option–Tab switches Otto spaces using a centred floating panel with each space’s icon and name.

- Tap Option–Tab and release Option to return to the previously used space.
- Hold Option and tap Tab repeatedly to cycle in recent-use order. Shift reverses the direction.
- Release Option to open the highlighted space. Arrow keys also move the selection; Return opens it.
- Escape, clicking the backdrop, or leaving the workspace window cancels the gesture.
- Clicking a profile opens it directly. Long lists scroll to keep the keyboard selection visible.

The order freezes while the panel is open. Recent-use order is kept for this app run and is updated
by successful switches through any entry point, including the header menu. New/unvisited profiles
follow in registry order. A single-profile workspace leaves Option–Tab alone.

The monitor is local to Otto’s workspace window. It does not require Accessibility permission,
register a system-wide hotkey, or intercept shortcuts in Settings, sheets, or other apps. Browser
Control–Tab remains browser tab navigation. Settings → Shortcuts lists the space gestures.

Switching uses `OttoSpaceController.switchTo`: running agents, composer drafts and per-space UI
state keep their existing lifecycle. Opening failures leave the current runtime visible and show
an error. The selection is cleared before the asynchronous switch begins.

Verification: `ProfileKeyboardSwitcherTests` covers forward/backward cycling, frozen ordering,
modifier boundaries, Option release, Escape cancellation and the single-profile case.
`SpaceSwitchingTests` checks recent ordering alongside runtime/process continuity and failed opens.
Set `OTTO_PROFILE_SNAPSHOT_DIR` for a native SwiftUI snapshot of the panel.
