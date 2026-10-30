import Foundation

/// Threading headers shared by Gmail and SMTP replies. Values end up verbatim in a message's
/// headers, so anything that could break a header line or smuggle another header is rejected.
enum MailHeaders {
  /// Mail clients cap References; keep the newest IDs within a safe header length.
  static let referencesLimit = 900

  /// One `<local@domain>` message ID with no whitespace or line breaks.
  static func isMessageID(_ value: String) -> Bool {
    (3...998).contains(value.utf8.count) && value.hasPrefix("<") && value.hasSuffix(">")
      && value.dropFirst().dropLast().contains("@")
      && !value.dropFirst().dropLast().contains(where: { $0 == "<" || $0 == ">" })
      && !value.unicodeScalars.contains(where: {
        $0.value <= 32 || $0.value == 127 || !$0.isASCII
      })
  }

  /// The message ID in a header value, without the comments and spacing RFC 5322 allows around
  /// it, as in `<abc@example.com> (sent by X)`. Nil when there is no valid ID or the value holds
  /// a line break or other control character.
  static func messageID(in value: String) -> String? {
    guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
      let start = value.firstIndex(of: "<"),
      let end = value[start...].firstIndex(of: ">")
    else { return nil }
    let id = String(value[start...end])
    return isMessageID(id) ? id : nil
  }

  /// The original's References with its own Message-ID added, as RFC 5322 asks of a reply.
  /// Invalid entries are dropped and the oldest IDs give way once the header grows too long.
  static func references(appending messageID: String, to existing: String?) -> String {
    var ids = (existing ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
      .filter(isMessageID)
    if !ids.contains(messageID) { ids.append(messageID) }
    while ids.count > 1, ids.joined(separator: " ").utf8.count > referencesLimit {
      ids.removeFirst()
    }
    return ids.joined(separator: " ")
  }
}
