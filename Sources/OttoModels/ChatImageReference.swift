import Foundation

/// The standalone Markdown image contract shared by transcript storage and chat rendering.
public struct ChatImageReference: Equatable, Sendable {
  public let alt: String
  public let target: String

  public static func parse(_ line: String) -> Self? {
    let line = line.trimmingCharacters(in: .whitespaces)
    guard line.hasPrefix("!["), line.hasSuffix(")"), let split = line.range(of: "](") else {
      return nil
    }
    let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<split.lowerBound])
    var target = String(line[split.upperBound..<line.index(before: line.endIndex)])
    if target.hasPrefix("<"), target.hasSuffix(">") {
      target = String(target.dropFirst().dropLast())
      guard !target.contains(">"), !target.contains("<") else { return nil }
    } else {
      var depth = 0
      for character in target {
        if character == "(" { depth += 1 }
        if character == ")" { depth -= 1 }
        if depth < 0 { return nil }
      }
      guard depth == 0 else { return nil }
    }
    guard !target.isEmpty else { return nil }
    return Self(alt: alt, target: target)
  }

  public static func localURL(_ target: String, directory: URL?) -> URL? {
    if target.hasPrefix("/") { return URL(fileURLWithPath: target).standardizedFileURL }
    if let url = URL(string: target), let scheme = url.scheme {
      guard scheme.lowercased() == "file",
        url.host == nil || url.host == "" || url.host == "localhost"
      else { return nil }
      return url.standardizedFileURL
    }
    let decoded = target.removingPercentEncoding ?? target
    guard let directory, !NSString(string: decoded).pathComponents.contains("..") else {
      return nil
    }
    return directory.appendingPathComponent(decoded)
      .standardizedFileURL
  }
}
