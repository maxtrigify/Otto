# Photon feedback

Otto uses the pinned Spectrum 12.8.0 SDK's Space.read(message),
startTyping(), and stopTyping() APIs. Read signals are sent only after durable
acceptance of an authenticated inbound event, including successful pairing.
iMessage read state is chat-level; it is not proof a person read a specific message.

Typing is best effort, refreshed every eight seconds while the team is running,
and stopped on completion, desktop approval, offline state, or disconnect.
Signal failures do not change request or delivery state. SDK signal calls have a
three-second command-queue budget; the underlying provider operation may complete
later, so handset indicators are not a durable activity guarantee.

After fifteen seconds from request receipt, an active request may enqueue one
persisted "your team is working" acknowledgement. It uses the regular bounded
outbox and uncertain-delivery rules. An unsent acknowledgement is cancelled when
the request is no longer active. It is never interpreted as the final answer.

Tests use simulated provider objects and in-memory secrets. Actual read/typing
visibility depends on Photon and the handset and must be checked live.
