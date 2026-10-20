# Question cards

Paper source: [Otto — Questions · clear choices / Questions · in conversation](https://app.paper.design/file/01M1NQS8VTQC85KZXPXWHSVTGB/1-0).

`AgentChoiceCard` renders structured `AgentChoicePrompt` requests in the shared conversation body used by bots and sessions. It replaces the old clipped option rows inside the amber attention notice. Permissions and provider sign-in keep their existing notices.

- Single choice: clicking the full row sends its original option string immediately. A recommendation is a label, never a default selection.
- Multiple choices: selections toggle without sending; Continue submits them in displayed order, using the existing comma-separated answer contract.
- Custom answer: Write my own answer opens an inline editor. Back to choices preserves the draft and selection. Empty/whitespace answers cannot be sent. The normal composer continues to answer the pending question through the existing choice channel.
- Submission makes the card read-only and shows the answer until the runtime clears the pending question. Existing transcript persistence remains responsible for answer history. Replacing a prompt resets local card state.
- Options split title and supporting text at ` — `; a trailing `(Recommended)` on the title becomes a separate label. This formatting never changes the value sent to the agent.

## Appearance

Use Avenir Next and `OttoPalette`, with an opaque `raised` reading surface even on glass themes. The Paper dimensions are 14-point card corners, 24-point padding, 20-point section spacing, 15-point option titles and 13-point supporting text. Rows grow to fit long content; the recommendation moves underneath when the inline heading cannot fit. The same layout adapts to narrow canvas nodes.

Selection and hover use the active theme's signal hue. Accent text falls back to the theme's paper colour if signal-on-raised contrast is below 4.5:1. Filled action buttons choose a foreground with at least 4.5:1 contrast against signal, including custom themes. There are no Glasswing hex colours in the component. Reduce Motion disables hover animation; native buttons remain keyboard-accessible and expose selection to accessibility.

## Validation

Run `scripts/otto-swift test --filter 'AgentChoiceCardTests|MarkdownThemeTests|AssistantResponsePresentationTests'`.
Set `OTTO_CHOICE_SNAPSHOTS` to a local output directory to also render AppKit-hosted SwiftUI PNGs at 390 and 760 points in Glasswing, Nightspire and Field Notes, covering single choice, selected multiple choices, custom answers, free-text-only questions and answered receipts. These are review artifacts, not pixel-golden tests.

Validated: 16 tests across question-card behavior, theme contrast, Markdown theme invalidation and existing visual-response presentation. Reviewed native captures in Glasswing, Nightspire and Field Notes.
