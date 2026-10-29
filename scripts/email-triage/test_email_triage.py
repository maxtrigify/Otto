"""Offline tests for email_triage. Run: python3 -m unittest discover -s scripts/email-triage"""

import unittest
from email.message import EmailMessage

import email_triage as triage


def make_message(
    sender="Alice <alice@example.com>",
    subject="Quick question",
    body="Can you approve the invoice by Friday?",
    html=None,
    headers=None,
) -> bytes:
    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = "bot@example.com"
    msg["Subject"] = subject
    msg["Date"] = "Thu, 29 Oct 2026 09:00:00 +0000"
    msg.set_content(body)
    if html is not None:
        msg.add_alternative(html, subtype="html")
    for name, value in (headers or {}).items():
        msg[name] = value
    return msg.as_bytes()


class HtmlToTextTests(unittest.TestCase):
    def test_drops_script_style_and_keeps_text(self):
        markup = "<html><head><title>T</title></head><body><style>p{}</style><p>Hi <b>there</b></p><script>x()</script></body></html>"
        text = triage.html_to_text(markup)
        self.assertIn("Hi there", text)
        self.assertNotIn("x()", text)
        self.assertNotIn("p{}", text)
        self.assertNotIn("T", text.split())

    def test_block_tags_break_lines(self):
        self.assertIn("\n", triage.html_to_text("<div>one</div><div>two</div>"))


class DistillTests(unittest.TestCase):
    def test_prefers_plain_text_and_strips_quoted_reply(self):
        raw = make_message(
            body="Please approve the invoice.\n\nOn Wed, Bob wrote:\n> old stuff",
            html="<p>HTML version</p>",
        )
        record = triage.distill(raw, 7, blocked=set(), allowed=set())
        self.assertIsNotNone(record)
        self.assertIn("Please approve the invoice.", record["body"])
        self.assertNotIn("old stuff", record["body"])
        self.assertNotIn("HTML version", record["body"])
        self.assertEqual(record["uid"], 7)
        self.assertEqual(record["subject"], "Quick question")
        self.assertNotIn("message_id", record)

    def test_keeps_threading_headers_for_replies(self):
        raw = make_message(
            headers={
                "Message-ID": "<m2@example.com>",
                "Reply-To": "billing@example.com",
                "References": "<m0@example.com>   <m1@example.com>",
            }
        )
        record = triage.distill(raw, 8, blocked=set(), allowed=set())
        self.assertEqual(record["message_id"], "<m2@example.com>")
        self.assertEqual(record["reply_to"], "billing@example.com")
        self.assertEqual(record["references"], "<m0@example.com> <m1@example.com>")

    def test_falls_back_to_html_when_no_plain_part(self):
        msg = EmailMessage()
        msg["From"] = "alice@example.com"
        msg["Subject"] = "Meeting"
        msg["Date"] = "Thu, 29 Oct 2026 09:00:00 +0000"
        msg.add_alternative("<p>Can we schedule a <b>meeting</b>?</p>", subtype="html")
        record = triage.distill(msg.as_bytes(), 1, blocked=set(), allowed=set())
        self.assertIsNotNone(record)
        self.assertIn("schedule a meeting", record["body"])

    def test_body_is_bounded(self):
        raw = make_message(subject="Please read", body="word " * 5000)
        record = triage.distill(raw, 2, blocked=set(), allowed=set())
        self.assertLessEqual(len(record["body"]), triage.MAX_BODY_CHARS)

    def test_idle_chatter_is_skipped(self):
        raw = make_message(subject="FYI", body="Just letting you know the weather is fine.")
        self.assertIsNone(triage.distill(raw, 3, blocked=set(), allowed=set()))

    def test_blocked_sender_and_domain_are_skipped(self):
        raw = make_message(sender="spam@bad.example", body="Please approve now")
        self.assertIsNone(triage.distill(raw, 4, blocked={"spam@bad.example"}, allowed=set()))
        self.assertIsNone(triage.distill(raw, 4, blocked={"bad.example"}, allowed=set()))

    def test_bulk_and_spam_headers_are_skipped(self):
        cases = [
            {"X-Spam-Flag": "YES"},
            {"Precedence": "bulk"},
            {"List-Unsubscribe": "<mailto:x@example.com>"},
            {"Auto-Submitted": "auto-replied"},
        ]
        for headers in cases:
            with self.subTest(headers=headers):
                raw = make_message(body="Please approve this", headers=headers)
                self.assertIsNone(triage.distill(raw, 5, blocked=set(), allowed=set()))

    def test_allowed_sender_always_passes(self):
        raw = make_message(sender="boss@work.example", subject="Hello", body="Thanks")
        record = triage.distill(raw, 6, blocked=set(), allowed={"boss@work.example"})
        self.assertIsNotNone(record)


class UidTests(unittest.TestCase):
    def test_new_uids_ignores_already_seen_highest_uid(self):
        # UID SEARCH n:* returns the highest UID even when it is below n.
        self.assertEqual(triage.new_uids([b"5"], last_uid=5), [])
        self.assertEqual(triage.new_uids([b"6 7 9"], last_uid=5), [6, 7, 9])

    def test_new_uids_handles_empty_reply(self):
        self.assertEqual(triage.new_uids([None], last_uid=0), [])
        self.assertEqual(triage.new_uids([b""], last_uid=0), [])


if __name__ == "__main__":
    unittest.main()
