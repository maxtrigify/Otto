import Foundation
import OttoModels
import OttoTools
import Testing

@testable import OttoServices

@Suite("Email replies")
struct EmailRepliesTests {
  @Test("Message IDs must be one bracketed address with nothing that breaks a header")
  func messageIDs() {
    #expect(MailHeaders.isMessageID("<abc.123@example.com>"))
    #expect(!MailHeaders.isMessageID("abc@example.com"))
    #expect(!MailHeaders.isMessageID("<abc@example.com>\r\nBcc: spy@example.com"))
    #expect(!MailHeaders.isMessageID("<a b@example.com>"))
    #expect(!MailHeaders.isMessageID("<a@b> <c@d>"))
    #expect(!MailHeaders.isMessageID("<nodomain>"))
  }

  @Test("References keep the thread, add the replied-to ID once and drop the oldest when long")
  func references() {
    #expect(
      MailHeaders.references(appending: "<m2@x>", to: "<m0@x>  <m1@x> junk")
        == "<m0@x> <m1@x> <m2@x>")
    #expect(MailHeaders.references(appending: "<m1@x>", to: "<m1@x>") == "<m1@x>")
    let long = (0..<200).map { "<message-\($0)@example.com>" }.joined(separator: " ")
    let trimmed = MailHeaders.references(appending: "<last@example.com>", to: long)
    #expect(trimmed.utf8.count <= MailHeaders.referencesLimit)
    #expect(trimmed.hasSuffix("<message-199@example.com> <last@example.com>"))
  }

  @Test("An SMTP reply carries In-Reply-To and References")
  func smtpReplyHeaders() throws {
    let text = try SMTPConnector.message(
      from: "bot@example.com", to: "amy@example.com", subject: "Re: Invoice", body: "Done",
      date: Date(timeIntervalSince1970: 0), messageID: "<new@example.com>",
      inReplyTo: "<m1@example.com>", references: "<m0@example.com>")
    #expect(text.contains("In-Reply-To: <m1@example.com>\r\n"))
    #expect(text.contains("References: <m0@example.com> <m1@example.com>\r\n"))
    let plain = try SMTPConnector.message(
      from: "bot@example.com", to: "amy@example.com", subject: "Hi", body: "x",
      date: .now, messageID: "<new@example.com>")
    #expect(!plain.contains("In-Reply-To"))
    #expect(throws: SMTPError.invalidField("In-Reply-To")) {
      try SMTPConnector.message(
        from: "bot@example.com", to: "amy@example.com", subject: "Hi", body: "x",
        date: .now, messageID: "<new@example.com>",
        inReplyTo: "<m1@example.com>\r\nBcc: spy@example.com")
    }
  }

  @Test("A Gmail reply is threaded under the original message")
  func gmailReplyThread() throws {
    let original: JSONValue = .object([
      "id": .string("abc"), "threadId": .string("thread-1"),
      "payload": .object([
        "headers": .array([
          .object(["name": .string("Message-Id"), "value": .string("<m1@mail.example.com>")]),
          .object(["name": .string("References"), "value": .string("<m0@mail.example.com>")]),
        ])
      ]),
    ])
    let thread = try GmailMessageCodec.replyThread(original)
    #expect(thread.threadID == "thread-1")
    #expect(thread.references == "<m0@mail.example.com> <m1@mail.example.com>")
    let raw = try GmailMessageCodec.raw(
      to: "amy@example.com", subject: "Re: Hello", body: "Thanks", replyingTo: thread)
    let decoded = String(decoding: try #require(Data(base64URL: raw)), as: UTF8.self)
    #expect(decoded.contains("In-Reply-To: <m1@mail.example.com>\r\n"))
    #expect(decoded.contains("References: <m0@mail.example.com> <m1@mail.example.com>\r\n"))

    let noMessageID: JSONValue = .object([
      "threadId": .string("thread-1"), "payload": .object(["headers": .array([])]),
    ])
    #expect(throws: AppConnectionError.invalidMessage) {
      try GmailMessageCodec.replyThread(noMessageID)
    }
  }

  @Test("The triage inbox lists unhandled mail newest first and forgets handled mail")
  func triageInbox() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "triage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inbox = EmailTriageInbox(directory: directory)
    #expect(try inbox.pending(limit: 10).isEmpty)

    let lines = [
      #"{"uid": 1, "from": "Amy <amy@example.com>", "subject": "Invoice?", "date": null, "body": "Approve?", "message_id": "<m1@example.com>"}"#,
      "not json",
      #"{"uid": 2, "from": "bob@example.com", "subject": "Meeting", "date": "2026-10-29T09:00:00+00:00", "body": "Thursday?"}"#,
      #"{"uid": 1, "from": "Amy <amy@example.com>", "subject": "Invoice?", "date": null, "body": "Approve?", "message_id": "<m1@example.com>"}"#,
    ]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: inbox.outboxURL)

    let pending = try inbox.pending(limit: 10)
    #expect(pending.map(\.uid) == [1, 2])
    #expect(pending.first?.key == "<m1@example.com>")
    #expect(pending.last?.key == "uid:2|2026-10-29T09:00:00+00:00|Meeting")
    #expect(try inbox.pending(limit: 1).count == 1)

    try inbox.markHandled(["<m1@example.com>"])
    #expect(try inbox.pending(limit: 10).map(\.uid) == [2])
    #expect(EmailTriageInbox.address("Amy <amy@example.com>") == "amy@example.com")
    #expect(EmailTriageInbox.address(" bob@example.com ") == "bob@example.com")
  }
}
