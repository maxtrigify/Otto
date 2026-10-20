# Inline email and inbox results

Paper source: [Actionable replies · Email draft / Inbox and inline reply](https://app.paper.design/file/01M1NQS8VTQC85KZXPXWHSVTGB/1-0).

The shared Markdown renderer supports fenced `otto-email` and `otto-inbox` JSON.
These render in sessions, bot conversations, and expanded canvas conversations.
The email card uses Paper's opaque raised surface, 14-point corners, 24-point
reading padding, recipient/subject lanes, full body, and responsive action footer.

```otto-email
{"to":"Hugo","subject":"What Otto is","body":"Hey Hugo,\n\nOtto is a shared visual workspace.\n\nMax"}
```

Email cards copy the full email, edit/save a local draft, and open a percent-encoded
mailto draft in the default mail app. Local edits are retained in app preferences
by the response ID and original draft's content hash; separate replies keep separate edits. The
provider transcript is never rewritten. Opening a mail app is not sending email.
Unknown recipients remain empty; legacy `Subject:` letters do not infer an address
from a greeting. The user can supply one while editing or in their mail app.

```otto-inbox
{"title":"Inbox","messages":[{"sender":"Hugo","subject":"Walkthrough","body":"Does Thursday work?","unread":true,"receivedAt":"2026-09-08 09:42","replyTo":"hugo@example.com","url":"https://mail.example.com/message/1","replyBody":"Hey Hugo, Thursday works."}]}
```

Inbox cards display snapshots of retrieved messages, filter unread results,
expand message bodies, open verified HTTP(S) source links, and compose replies
inline using the email card. `sender`, `subject`, and `body` are required; other
message fields are optional. There is no mailbox mutation or sending action:
refresh, mark-read and direct send require connector-backed action dispatch and
are deliberately not represented as working controls. Empty inboxes have an
explicit empty state. Invalid, oversized, or unfinished fenced payloads fall back
to readable code; they never execute HTML or actions automatically.

Unmarked responses no longer collapse based on character count. Requested writing
and all composed results remain visible. An explicit `<!-- otto:details -->` may
hide supporting prose, but never a result card, image, table, or diagram beneath it.
Existing complete `Subject:` letters with a greeting are recognized as email cards,
including the September 8 email to Hugo that previously showed only its subject.

Validation: `ChatResultTests`, `AssistantResponsePresentationTests`, Markdown tests,
and provider-adapter tests. Set `OTTO_RESULT_SNAPSHOTS` to a local output directory
when running `ChatResultTests` to capture native cards at 390/900 points across
Field Notes, Nightspire, and Glasswing.
