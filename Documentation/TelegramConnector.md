# Telegram connector and Connectors hub

**Connectors** is Otto's central place for current and future connections.
It brings Telegram, Photon/iMessage messaging, Mobile phone pairing, Gmail,
Google Calendar and Email (SMTP) together as tiles. Each connector has its own
list of Otto bots allowed to use it; nothing is allowed until the Mac owner
ticks a bot. Other integrations (for example WhatsApp) can be added
to this same hub in the future; **WhatsApp is not implemented in this change**.
The Telegram integration is independent of the existing Photon/iMessage connector.

## Setup

1. Open **Settings → Connectors** and click the **Telegram** tile. The
   other connectors are tiles on the same page; each opens its own setup with
   a back button to the hub.
2. In Telegram, open [@BotFather](https://t.me/BotFather), send `/newbot`,
   and create a bot. Telegram supplies the bot's **bot token**.
3. Paste that token in Otto's secure field and click **Connect Telegram**.
   Otto verifies the token through Telegram's `getMe` API and stores it
   in macOS Keychain, never a project file.
4. Under **Otto bots that can use Telegram** tick each saved bot Telegram may
   reach. Leaving every bot unticked disables dispatch. Chats can switch only
   among ticked bots; they can never reach a bot the Mac has not allowed.
5. To connect a **private chat**, send the exact `/pair CODE` shown in Otto
   and approve the requesting chat on the Mac. The code expires in ten minutes.
6. To connect a **group**, generate a **group pairing code**,
   add the Telegram bot to the group, and send `/pair CODE` there. Review and
   approve **both the group ID and the sender ID** on the Mac. Only the member
   who initiated pairing can send Otto requests; all other group members are
   ignored. Group pairing does not revoke any previously authorized private chat.
7. Use `/bots` to list the allowed bots, `/use @handle` to pick the bot for
   this chat, or `/bot @handle message` to ask one bot once. Ordinary text goes
   to the chat's bot, which defaults to the first allowed bot and resets when
   Otto restarts.
   Telegram's default privacy mode may prevent bots from seeing ordinary group
   text. In BotFather, use `/setprivacy` → **Disable** and remove/re-add the
   bot to that group if you want normal messages like `Test` to reach Otto.

## Photos and videos

Photos, videos, round video notes, GIFs (Telegram sends them as video) and
files Telegram labels as an image or video go to the chat's bot, with the
caption as the message. Start a caption with `/bot @handle` to send it to one
allowed bot; `/bot @handle` alone sends just the media.

- Only the paired person's media is downloaded, into
  `<workspace>/.otto/chat-attachments/telegram/`, the same place as images
  pasted into Chat. The bot's prompt lists the files with Otto's usual
  attached-images note, so any harness opens them with its own tools and the
  chat shows them as images.
- The photos and videos of one album arrive as separate Telegram messages.
  Otto waits until no more arrive for 1.5 seconds (at most ten items) and
  sends them as one message.
- Agents can't watch video, so Otto takes up to four still frames from each
  video and attaches them. When on-device speech is set up for voice notes,
  videos up to five minutes also have their sound transcribed. The video file
  itself is kept and its path is in the prompt.
- The Bot API serves files up to 20 MB. Larger items are refused with a note;
  the rest of an album is still sent.

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
- Supported: private and group text, Mac-controlled bot access, prompt dispatch, and best-effort
  bot replies. Interactive bot sessions and some long-running work may require
  opening Otto for the result. The app must be open and running.
- Delivery is intentionally **at-most-once**: an update ID is persisted before
  dispatch to prevent accidental duplicate execution after a restart. A crash
  between acknowledgement and dispatch could therefore require manual retry.
  Use Otto's local conversation history to review outcomes.
- One Telegram bot token, one private chat and one approved group can be configured per Otto
  workspace. Disconnect clears Keychain credentials and local authorization;
  rotate the token in BotFather if it may have been disclosed.
- No actual Telegram account/token is bundled or committed. Testing
  real send/receive behavior requires a user-owned BotFather token and chat.
