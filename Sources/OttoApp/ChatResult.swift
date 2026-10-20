import CryptoKit
import Foundation
import OttoModels

/// A small, provider-independent Markdown contract. Unknown or invalid payloads remain code.
struct ChatEmailDraft: Codable, Equatable {
  var to: String
  var subject: String
  var body: String

  var storageKey: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let source = (try? encoder.encode(self)) ?? Data()
    return "otto.emailDraft."
      + SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
  }

  var copyText: String {
    (to.isEmpty ? "" : "To: \(to)\n") + "Subject: \(subject)\n\n\(body)"
  }

  var mailURL: URL? {
    // Encode headers separately; recipient text cannot inject mailto query parameters.
    guard !to.contains(where: { $0.isNewline }), !subject.contains(where: { $0.isNewline })
    else { return nil }
    let recipient =
      to.addingPercentEncoding(
        withAllowedCharacters:
          CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@.,+-_"))) ?? ""
    var components = URLComponents(string: "mailto:\(recipient)")
    components?.queryItems = [
      URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body),
    ]
    return components?.url
  }

  static func legacy(_ source: String) -> Self? {
    let lines = source.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
    guard let first = lines.first else { return nil }
    let header = first.replacingOccurrences(of: "**", with: "")
    guard header.hasPrefix("Subject: ") else { return nil }
    let subject = String(header.dropFirst(9)).trimmingCharacters(in: .whitespaces)
    let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(
      in: .whitespacesAndNewlines)
    // Only recognize a complete letter, not a discussion mentioning an email subject.
    guard !subject.isEmpty, body.contains("\n"),
      ["Hi ", "Hey ", "Hello ", "Dear "].contains(where: { body.hasPrefix($0) }),
      !body.contains("```"), OttoTranscriptMarkers.detailsMarkerRange(in: body) == nil
    else { return nil }
    return Self(to: "", subject: subject, body: body)
  }
}

struct ChatInbox: Codable, Equatable {
  var title: String
  var messages: [Message]

  struct Message: Codable, Equatable {
    var sender: String
    var subject: String
    var body: String
    var receivedAt: String?
    var unread: Bool?
    var url: String?
    var replyTo: String?
    var replyBody: String?

    var originalURL: URL? {
      guard let url, let parsed = URL(string: url),
        ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil
      else { return nil }
      return parsed
    }

    var reply: ChatEmailDraft {
      ChatEmailDraft(
        to: replyTo ?? "",
        subject: subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)",
        body: replyBody ?? "")
    }
  }
}

enum ChatResult {
  static func decode<T: Decodable>(_ type: T.Type, from source: String) -> T? {
    guard source.utf8.count <= 200_000 else { return nil }
    return try? JSONDecoder().decode(type, from: Data(source.utf8))
  }

  static func block(language: String, source: String) -> MarkdownBlockContent? {
    let language = language.lowercased()
    switch language {
    case _ where OttoTranscriptMarkers.emailFences.contains(language):
      guard let draft = decode(ChatEmailDraft.self, from: source), !draft.subject.isEmpty,
        !draft.body.isEmpty
      else { return nil }
      return .email(draft)
    case _ where OttoTranscriptMarkers.inboxFences.contains(language):
      guard let inbox = decode(ChatInbox.self, from: source), inbox.messages.count <= 100,
        inbox.messages.allSatisfy({ !$0.sender.isEmpty && !$0.subject.isEmpty })
      else { return nil }
      return .inbox(inbox)
    default: return nil
    }
  }
}
