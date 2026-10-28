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
4. Open your new Telegram bot's private chat, and send the exact `/pair CODE`
   shown in Otto. The code expires after 10 minutes. Otto displays the
   pending Telegram chat ID; verify it is yours and **Approve this Telegram chat**
   on the Mac. The pairing approval step cannot be completed from Telegram.
5. Send `/bots` in Telegram to list your saved Otto bots. Send
   `/use @handle` to choose a default. Ordinary text now goes to that bot.
   For a one-off message to another bot, use `/bot @handle message`.

## Security and limitations

- Only the explicitly Mac-approved **private** chat, with matching Telegram
  user and chat IDs, is allowed to dispatch. Group chats, other senders and
  bot-originated messages are ignored.
- Telegram is an untrusted input surface and **never grants Otto tool approvals**.
  Any required review, tool permission, or user question stays in Otto on Mac.
  Connected bots still have their existing configured tool permissions; use
  restricted bots for external messaging.
- Long polling uses Telegram's official HTTPS Bot API. No webhook, public
  Mac port or inbound connection is required. The bot token is in the API URL
  path as Telegram requires; redirects are forbidden and URLs/errors are never
  logged.
- Supported: private text, saved bot selection, prompt dispatch, and best-effort
  bot replies. Interactive bot sessions and some long-running work may require
  opening Otto for the result. The app must be open and running.
- Delivery is intentionally **at-most-once**: an update ID is persisted before
  dispatch to prevent accidental duplicate execution after a restart. A crash
  between acknowledgement and dispatch could therefore require manual retry.
  Use Otto's local conversation history to review outcomes.
- One Telegram bot token and one approved chat can be configured per Otto
  workspace. Disconnect clears Keychain credentials and local authorization;
  rotate the token in BotFather if it may have been disclosed.
- No actual Telegram account/token is bundled or committed. Final live
  send/receive validation needs a user-owned BotFather token and chat.
