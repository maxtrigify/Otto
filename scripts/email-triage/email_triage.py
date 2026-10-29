#!/usr/bin/env python3
"""Poll an IMAP inbox and hand only actionable, plain-text mail to a model.

Idle polling never calls a model. Each run reads unseen mail without marking
it read, drops spam and bulk mail, reduces every message to bounded plain text,
and appends only the messages that need action to an outbox file. Run it from
launchd or cron; it exits after one pass.

The password is read from the OTTO_IMAP_PASSWORD environment variable, never
from a command-line argument or a file.
"""

from __future__ import annotations

import argparse
import email
import imaplib
import json
import os
import re
import sys
from email import policy
from email.message import Message
from email.utils import parseaddr, parsedate_to_datetime
from html.parser import HTMLParser
from pathlib import Path

MAX_BODY_CHARS = 2000
BLOCK_TAGS = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "table"}
SKIP_TAGS = {"script", "style", "head", "title"}
ACTION_WORDS = re.compile(
    r"\b(please|urgent|asap|action required|deadline|due|invoice|approve|approval|"
    r"reply|respond|confirm|meeting|schedule|payment|verify|overdue)\b",
    re.IGNORECASE,
)
QUOTE_MARKERS = re.compile(
    r"^(On .+ wrote:|-{2,} ?Original Message ?-{2,}|From: .+)$", re.IGNORECASE
)


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._skip_depth = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in SKIP_TAGS:
            self._skip_depth += 1
        elif tag in BLOCK_TAGS:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in SKIP_TAGS and self._skip_depth:
            self._skip_depth -= 1

    def handle_data(self, data: str) -> None:
        if not self._skip_depth:
            self.parts.append(data)


def html_to_text(markup: str) -> str:
    extractor = _TextExtractor()
    extractor.feed(markup)
    extractor.close()
    return "".join(extractor.parts)


def plain_body(msg: Message) -> str:
    """Prefer the text/plain part; fall back to HTML converted to text."""
    plain: list[str] = []
    html: list[str] = []
    for part in msg.walk():
        if part.is_multipart() or part.get_content_disposition() == "attachment":
            continue
        content = part.get_content() if part.get_content_maintype() == "text" else ""
        if part.get_content_type() == "text/plain":
            plain.append(content)
        elif part.get_content_type() == "text/html":
            html.append(html_to_text(content))
    return "\n".join(plain or html)


def strip_quoted(text: str) -> str:
    kept: list[str] = []
    for line in text.splitlines():
        if line.lstrip().startswith(">") or QUOTE_MARKERS.match(line.strip()):
            break
        kept.append(line)
    return "\n".join(kept)


def condense(text: str) -> str:
    collapsed = re.sub(r"[ \t\r\f\v]+", " ", text)
    collapsed = re.sub(r"\n\s*\n+", "\n\n", collapsed).strip()
    return collapsed[:MAX_BODY_CHARS]


def skip_reason(msg: Message, blocked: set[str]) -> str | None:
    """Return why a message is not worth any model time, or None."""
    _, address = parseaddr(msg.get("From", ""))
    address = address.lower()
    domain = address.rpartition("@")[2]
    if address in blocked or domain in blocked:
        return "blocked sender"
    if (msg.get("X-Spam-Flag") or "").strip().upper() == "YES":
        return "spam flag"
    if (msg.get("Precedence") or "").strip().lower() in {"bulk", "junk", "list"}:
        return "bulk precedence"
    if msg.get("List-Unsubscribe"):
        return "mailing list"
    auto = (msg.get("Auto-Submitted") or "no").strip().lower()
    if auto != "no":
        return "automated"
    return None


def needs_action(sender: str, subject: str, body: str, allowed: set[str]) -> bool:
    _, address = parseaddr(sender)
    if address.lower() in allowed or address.lower().rpartition("@")[2] in allowed:
        return True
    return bool(ACTION_WORDS.search(subject) or "?" in subject or ACTION_WORDS.search(body))


def distill(raw: bytes, uid: int, blocked: set[str], allowed: set[str]) -> dict | None:
    """Return a compact record for actionable mail, or None to skip it."""
    msg = email.message_from_bytes(raw, policy=policy.default)
    if skip_reason(msg, blocked):
        return None
    body = condense(strip_quoted(plain_body(msg)))
    sender = str(msg.get("From", ""))
    subject = str(msg.get("Subject", ""))
    if not needs_action(sender, subject, body, allowed):
        return None
    date = msg.get("Date")
    try:
        when = parsedate_to_datetime(str(date)).isoformat() if date else None
    except (TypeError, ValueError):
        when = None
    return {"uid": uid, "from": sender, "subject": subject, "date": when, "body": body}


def new_uids(search_reply: list[bytes], last_uid: int) -> list[int]:
    """UID SEARCH 'n:*' always returns the highest UID even when it is below n."""
    found: list[int] = []
    for chunk in search_reply:
        for token in (chunk or b"").split():
            if token.isdigit() and int(token) > last_uid:
                found.append(int(token))
    return sorted(found)


def load_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {"uidvalidity": None, "last_uid": 0}


def save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state))


def poll(args: argparse.Namespace) -> int:
    password = os.environ.get("OTTO_IMAP_PASSWORD")
    if not password:
        print("OTTO_IMAP_PASSWORD is not set", file=sys.stderr)
        return 2
    blocked = {line.strip().lower() for line in _lines(args.blocked)}
    allowed = {line.strip().lower() for line in _lines(args.allowed)}
    state = load_state(args.state)

    client = imaplib.IMAP4_SSL(args.host, args.port)
    try:
        client.login(args.user, password)
        _, data = client.select(args.mailbox, readonly=True)  # EXAMINE: no flag changes
        validity = int(client.response("UIDVALIDITY")[1][0])
        if state["uidvalidity"] != validity:
            state = {"uidvalidity": validity, "last_uid": 0}
        _, search = client.uid("SEARCH", None, f"UID {state['last_uid'] + 1}:*")
        uids = new_uids(search, state["last_uid"])

        written = 0
        args.outbox.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(args.outbox, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as outbox:
            for uid in uids:
                _, fetched = client.uid("FETCH", str(uid), "(BODY.PEEK[])")
                raw = next((part[1] for part in fetched if isinstance(part, tuple)), b"")
                record = distill(raw, uid, blocked, allowed)
                if record:
                    outbox.write(json.dumps(record, ensure_ascii=False) + "\n")
                    written += 1
                state["last_uid"] = uid  # skipped mail is also consumed
        save_state(args.state, state)
        print(f"checked {len(uids)} new message(s); {written} need action", file=sys.stderr)
        return 0
    finally:
        try:
            client.logout()
        except (imaplib.IMAP4.error, OSError):
            pass


def _lines(path: Path | None) -> list[str]:
    if path is None or not path.exists():
        return []
    return path.read_text().splitlines()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=993)
    parser.add_argument("--user", required=True)
    parser.add_argument("--mailbox", default="INBOX")
    parser.add_argument("--state", type=Path, default=Path.home() / ".otto/email-triage/state.json")
    parser.add_argument("--outbox", type=Path, default=Path.home() / ".otto/email-triage/outbox.jsonl")
    parser.add_argument("--blocked", type=Path, help="one sender address or domain per line")
    parser.add_argument("--allowed", type=Path, help="senders that always need action")
    return poll(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
