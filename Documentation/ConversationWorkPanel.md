# Conversation work-panel visibility

The right work panel has independent open/closed state for each saved bot, session and team within the Chat view. Switching away and back restores that conversation's state; a conversation without a prior choice starts closed. Visibility uses typed sidebar identities (`bot:`, `session:`, `team:`), so bot runtime replacement does not lose its choice and bot/session views cannot collide. Width remains the existing shared preference. This does not add persistence of open/closed state across app launches.

Verified in installed Otto Dev on 1 October 2026: open Coda session panel; switch to Coder (closed); open Coder; switch to Researcher (closed); return to Coda (open); close Coda; return to Coder (still open). Restored panels closed afterward. Guarded app build passed (`/tmp/muse-per-chat-panel-build.log`); strict formatting and diff checks passed. No model calls were made.
