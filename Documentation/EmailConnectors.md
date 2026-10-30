# Email: SMTP sending and low-token inbox triage

## Sending mail (Email (SMTP) connector)

Open **Settings → Connectors → Email (SMTP)**, enter the server, port, username, from address
and password, and **Save**. Use port 465 with **Use implicit TLS** on, or port 587 with it off
(STARTTLS). **Test connection** logs in and sends `NOOP`; it never sends mail.

- Agents send with `smtp.send` (one bare recipient, subject, plain-text body). Every send goes
  through Otto's exact-call approval card and is never retried automatically.
- Only bots ticked under **Otto bots that can use Email (SMTP)** see the tool. Read-only bots,
  archived bots and ad-hoc sessions cannot send.
- The password is stored in the Keychain (release builds) or the user-only development secrets
  file (development builds). Delivery uses the system `curl`; the login reaches it through a
  0600 config file in a 0700 temporary directory that is removed after each call, never argv.
- The server must be a plain host name and the from address a bare `name@domain`; header
  values with line breaks are rejected, so callers cannot inject headers or recipients.

Agent providers keep their own approval layers. Otto launches Codex with
`default_tools_approval_mode = "approve"` and Claude Code with `--allowedTools mcp__otto` in
ask-to-approve mode, so Otto's card is the single approval for Otto tools. Grok, Kimi, Cursor and
Pi rely on their existing launch flags.

## Reading mail without spending tokens (`scripts/email-triage`)

`email_triage.py` polls an IMAP inbox from launchd or cron and exits after one pass. It reads
unseen mail read-only (`EXAMINE` + `BODY.PEEK`), drops blocked senders, spam-flagged, bulk and
auto-submitted mail, converts HTML to text, strips quoted replies, caps each body at 2,000
characters and appends only messages that need action to an outbox JSONL file. Idle polling
never calls a model. The password comes from `OTTO_IMAP_PASSWORD`.

```sh
OTTO_IMAP_PASSWORD=... python3 scripts/email-triage/email_triage.py \
  --host imap.example.com --user me@example.com --allowed allowed.txt --blocked blocked.txt
python3 -m unittest discover -s scripts/email-triage
```

The outbox is not yet exposed as an Otto tool; agents do not read it automatically.
