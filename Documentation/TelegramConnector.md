# Telegram connector — local Mac test

This feature is intentionally local to the Mac branch until it has been tested.
It is independent of the existing Photon/iMessage connector.

## Setup

1. Run the local Otto build on your Mac and click **Connectors** beside
   Home/Chat, or open **Settings → Connectors**. Use the Telegram tab; the
   iMessage (Photon) and Mobile pairing screens are next to it, in the same
   connector hub.
2. In Telegram, open [@BotFather](https://t.me/BotFather), send `/newbot`,
   and create a bot. Telegram supplies the bot's **bot token**.
3. Paste that token in Otto's secure field and click **Connect Telegram**.
   Otto verifies the token through Telegram's `getMe` API and stores it
   in macOS Keychain, never a project file.
4. Under **Connected Otto bot** select the single saved Otto bot that this
   connector is permitted to message. Leaving it unselected disables dispatch.
   Telegram `/use` and `/bot` cannot override the Mac's selection.
5. To connect a **private chat**, send the exact `/pair CODE` shown in Otto
   and approve the requesting chat on the Mac. The code expires in ten minutes.
6. To connect a **group** (for example Nora), generate a **group pairing code**,
   add the Telegram bot to the group, and send `/pair CODE` there. Review and
   approve **both the group ID and the sender ID** on the Mac. Only the member
   who initiated pairing can send Otto requests; all other group members are
   ignored. Group pairing does not revoke any previously authorized private chat.
7. Use `/bots` to check the Mac-selected bot, then send ordinary text.
   Telegram's default privacy mode may prevent bots from seeing ordinary group
   text. In BotFather, use `/setprivacy` → **Disable** and remove/re-add the
   bot to that group if you want normal messages like `Test` to reach Otto.

## Security and limitations

- Only a Mac-approved private chat or a Mac-approved **group plus its named
  sender** can dispatch. Other group members, other groups, anonymous admins
  and bot-originated messages are ignored. Group approvals can be revoked
  without affecting private access.
- Telegram is an untrusted input surface and **never grants Otto tool approvals**.
  Any required review, tool permission, or user question stays in Otto on Mac.
  Connected bots still have their existing configured tool permissions; use
  restricted bots for external messaging.
- Long polling uses Telegram's official HTTPS Bot API. No webhook, public
  Mac port or inbound connection is required. The bot token is in the API URL
  path as Telegram requires; redirects are forbidden and URLs/errors are never
  logged.
- Supported: private and group text, Mac-controlled bot selection, prompt dispatch, and best-effort
  bot replies. Interactive bot sessions and some long-running work may require
  opening Otto for the result. The app must be open and running.
- Delivery is intentionally **at-most-once**: an update ID is persisted before
  dispatch to prevent accidental duplicate execution after a restart. A crash
  between acknowledgement and dispatch could therefore require manual retry.
  Use Otto's local conversation history to review outcomes.
- One Telegram bot token, one private chat and one approved group can be configured per Otto
  workspace. Disconnect clears Keychain credentials and local authorization;
  rotate the token in BotFather if it may have been disclosed.
- No actual Telegram account/token is bundled or committed. Final live
  send/receive validation needs a user-owned BotFather token and chat.
