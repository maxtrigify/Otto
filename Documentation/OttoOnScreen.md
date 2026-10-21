# Otto on screen

An opt-in desktop buddy: Otto floats over every app, strolls along the top of the Dock, can be
picked up and dropped, opens quick shortcuts when clicked, and says when work finishes, fails or
needs approval. Answers to questions come back in his speech bubble.

## Turning it on

- Settings › Otto on Screen › Show Otto on screen (off by default; `otto.buddy.enabled`).
- Window menu › Show Otto on Screen.
- While he is on, a menu bar item (eyes) offers Show, Nap/Wake, Open Otto and Settings.
- Right-click Otto: Nap for an Hour, Open Otto, Settings, Hide Otto.
- Offered once in the welcome flow ("Want me to hang out on your screen?") and as the last item
  of Home's Getting started checklist (ticked once he has appeared, `otto.buddy.everShown`).
- ⌥⌘O from any app opens his quick menu with the ask box ready (and wakes him). It is a Carbon
  hot key, so it needs no Accessibility permission, and it is registered only while he is on
  screen. If another app already owns ⌥⌘O the registration quietly stays off.

Other switches (all default on): Walk around, Say when things finish, Hide when an app is full
screen. Size S/M/L. "Otto answers with" picks the provider for the Buddy chat (default Codex).

## Asking

- Questions go to **Otto** by default: one ongoing session named "Buddy chat"
  (`otto.buddy.chatNodeID`). It is an ordinary Chat session, so every answer is kept.
- The "To" chip picks a recent chat or a bot; typing `@` suggests bots, and an `@handle`
  anywhere in the question routes it to that bot. After sending, the target resets to Otto.
- Replies come back in the bubble. Long answers show four lines, a word count, Open in Chat and
  Show more. The Reply box continues the same conversation.
- Ask about this screen captures the display under the pointer (without Otto's own windows)
  to `.otto/attachments/buddy/`, starts a new chat and asks about it. It needs Screen Recording
  permission; Otto explains and links to the setting if it's missing.
- A reply is detected from `agent.run_completed`, or from the session settling to idle after it
  worked, then read from `agent.get_status`'s result (falling back to the last assistant text).

## Speaking up

- Follows the same event bus as completion notifications. Finished or failed standalone sessions
  and bots get a bubble (skipped when you're already viewing that conversation in Otto).
- While he's out and "Say when things finish" is on, he replaces the macOS completion banners
  (`replacesCompletionBanners`). Napping, hidden for full screen or speaking off: banners return.
- `WAITING_PERMISSION` shows Approve / Deny / Review, resolved through
  `resolveAgentPermission`. `WAITING_USER` offers Open.
- He never talks over himself: while a reply, approval or the menu is open, new updates wait
  behind his orange badge and a "N updates waiting" row in his menu.

## Behaviour notes

- Panels are borderless, non-activating `NSPanel`s at floating level that join all Spaces, so
  clicking or typing into Otto never switches away from the app you're in.
- He naps after ten quiet minutes, rests while anything is open, and stops walking when Reduce
  Motion is on. Position is remembered (`otto.buddy.position`).
- Full screen is detected from the frontmost app's on-screen window covering a display. A menu
  or bubble you're using stays up.
- Window ledges: when he falls after a drop he lands on the first visible window top he passes
  (windows ≥ 240×120, edge not covered by a window in front), else the Dock. On a ledge he walks
  its width, rides along when the window moves, and falls when it closes, hides or is covered
  (checked 10× a second, only while on a ledge). Window bounds come from `CGWindowList`, which
  needs no Screen Recording permission.

## Cost

Walking must be close to free for something on screen all day. Measured on the window server
(average over 12 s, Otto walking vs not running): moving the panel every frame plus a
display-rate SwiftUI wobble with a blurred shadow cost about +33% CPU. Now the wobble is driven
from the same 30 Hz tick, the shadow is a static ellipse, and he walks across 24 pt of slack in
his window so the window itself moves about once a second. Walking now measures within noise
(+0–2%). The slack is click-through: `ignoresMouseEvents` follows whether the pointer is over
him.

## Development

- `OttoBuddyTests` covers preferences, mentions and reply sizing. Set `OTTO_BUDDY_SNAPSHOT_DIR`
  to render the bubbles, menu and settings to PNG.
- Debug builds listen for the distributed notification `app.otto.buddy.debug` with an object of
  `menu`, `draft:<text>`, `ask:<question>`, `note:<text>`, `drop:<x>,<y>`, `summon`,
  `status:<file>` or `snapshot:<path prefix>` (renders the live panels to PNG). Agent shells usually lack Screen Recording permission, so this
  is how the real panels are checked.
- Pose art lives in `Resources/Brand/Buddy` (from the website). Handwriting is Nanum Pen
  (`Resources/Fonts/NanumPenScript-Regular.ttf`, SIL OFL, unmodified).
